#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../probe.rkt"
         "../record.rkt"
         "../render.rkt"
         racket/file)

(define (probe-gcc r) "gcc-15.1")

(define-config base
  [label    () "nightly"]
  [copies   ((default 2))]
  [gcc-ver  (introduce (probe probe-gcc))]
  [hw-avail (introduce required)]
  [sw-avail (introduce required)])

(define r (resolve base))

;; 典型渲染器：读字段、发文本。entry-count 验证"单遍、前缀不重做"。
(define entry-count (box 0))
(define (render-cfg src emit)
  (set-box! entry-count (add1 (unbox entry-count)))
  (emit (format "label = ~a\n" (config-source-ref src 'label)))
  (emit (format "gcc = ~a\n" (config-source-ref src 'gcc-ver)))
  (emit (format "hw = ~a\n" (config-source-ref src 'hw-avail)))
  (emit (format "sw = ~a\n" (config-source-ref src 'sw-avail)))
  (emit (format "copies = ~a\n" (config-source-ref src 'copies))))

;; ---------------------------------------------------------------------------
;; 宽档（缺省）：占位入文本，verdict ok，缺失入报告

(define res (call-renderer r render-cfg))
(check-eq? (render-result-verdict res) 'ok)
(define text (render-result-product res))
(check-regexp-match #rx"label = nightly" text)
(check-regexp-match #rx"gcc = gcc-15.1" text)              ; 探测值（自动实探）
(check-regexp-match #rx"hw = <unfilled:hw-avail>" text)    ; 占位可格式化
(check-equal? (hash-ref (render-result-report res) 'unfilled-reads)
              '(hw-avail sw-avail))
(check-equal? (hash-ref (render-result-report res) 'read-set)
              '(label gcc-ver hw-avail sw-avail copies))

;; 占位对象可被应用检测
(check-true (unfilled-placeholder? (config-source-ref
                                    (with-probes r (probe-fields r))
                                    'hw-avail (lambda () (unfilled-placeholder 'hw-avail)))))

;; ---------------------------------------------------------------------------
;; 严档：挂起 → 删半成品 → writer 换 no-op → 占位恢复，单遍收全缺失

(define tmp (make-temporary-file "configkit-render-~a.cfg"))
(set-box! entry-count 0)
(define res2 (call-renderer r render-cfg
                            #:mode 'checked
                            #:writer (make-file-writer tmp)))
(check-eq? (render-result-verdict res2) 'failed)
(check-false (render-result-product res2))
(check-false (file-exists? tmp))                           ; 半成品已删
(check-equal? (unbox entry-count) 1)                       ; 单遍，前缀不重做
;; 失败点之后继续收集：两个缺失都在案，读集完整
(check-equal? (hash-ref (render-result-report res2) 'unfilled-reads)
              '(hw-avail sw-avail))
(check-equal? (hash-ref (render-result-report res2) 'read-set)
              '(label gcc-ver hw-avail sw-avail copies))

;; ---------------------------------------------------------------------------
;; parameterize 陷阱：失败读取包在 parameterize 内，恢复续延不得弹回 writer
;; （sink 若在 parameter 中，恢复后 suffix 会写回真 writer、重建半成品）

(define p (make-parameter 'outer))
(define tmp2 (make-temporary-file "configkit-render2-~a.cfg"))
(define (render-trap src emit)
  (emit "prefix\n")
  (parameterize ([p 'inner])
    (config-source-ref src 'hw-avail))       ; 失败点在 parameterize 帧内
  (emit "suffix-after-resume\n"))            ; 恢复后照发——必须落进 no-op
(define res3 (call-renderer r render-trap #:mode 'checked
                            #:writer (make-file-writer tmp2)))
(check-eq? (render-result-verdict res3) 'failed)
(check-false (file-exists? tmp2))

;; ---------------------------------------------------------------------------
;; 严档干净路径：文件产物完好

(define-config full
  #:extends base
  [hw-avail () "Jun-2026"]
  [sw-avail () "Jun-2026"])
(define tmp3 (make-temporary-file "configkit-render3-~a.cfg"))
(define res4 (call-renderer (resolve full) render-cfg #:mode 'checked
                            #:writer (make-file-writer tmp3)))
(check-eq? (render-result-verdict res4) 'ok)
(check-equal? (render-result-product res4) tmp3)
(check-regexp-match #rx"hw = Jun-2026" (file->string tmp3))
(delete-file tmp3)

;; ---------------------------------------------------------------------------
;; 与 probe 打通：注入假探测记录压过实探

(define res5 (call-renderer r render-cfg
                            #:probes (make-probes (hash 'gcc-ver "fake-gcc"))))
(check-regexp-match #rx"gcc = fake-gcc" (render-result-product res5))
(check-eq? (hash-ref (hash-ref (hash-ref (render-result-report res5) 'probes)
                               'gcc-ver)
                     'prober)
           'injected)

;; ---------------------------------------------------------------------------
;; 显式 fail 参数保留普通 ref 契约（绕过引擎策略，不挂起）；缺失仍在案

(define res6 (call-renderer r
               (lambda (src emit)
                 (emit (format "~a" (config-source-ref src 'hw-avail "N/A"))))
               #:mode 'checked))
(check-eq? (render-result-verdict res6) 'failed)
(check-equal? (render-result-product res6) "N/A")

;; ---------------------------------------------------------------------------
;; 逃逸的 emit 在失败后保持死透——box 换挡是全局的，parameterize 换挡
;; 只覆盖被恢复的动态范围，覆盖不到这里

(define leaked #f)
(define res7 (call-renderer r
               (lambda (src emit)
                 (set! leaked emit)
                 (config-source-ref src 'hw-avail)
                 (emit "after-resume"))
               #:mode 'checked))
(check-eq? (render-result-verdict res7) 'failed)
(check-not-exn (lambda () (leaked "post-render write")))   ; 无效调用，不异常

;; ---------------------------------------------------------------------------
;; 两段式驱动：未求解输入自动"纯求解→实探→带记录复解"，后验环境检查生效

(define (probe-cores r) 4)
(define-config env-render
  [host-cores (introduce (probe probe-cores))]
  [copies ((default 8)
           (validate/post
            (lambda (cfg)
              (define cores (config-probe-ref cfg 'host-cores 'unknown))
              (if (or (eq? cores 'unknown)
                      (<= (config-source-ref cfg 'copies) cores))
                  #t
                  "copies 超出宿主核数"))))])
(define res8 (call-renderer env-render (lambda (src emit) (emit "x"))))
(check-eq? (hash-ref (render-result-report res8) 'verdict) 'failed)

;; ---------------------------------------------------------------------------
;; no-op writer 与模式检查

(check-false (render-result-product
              (call-renderer r render-cfg #:writer (no-op-writer))))
(check-exn exn:fail:contract?
           (lambda () (call-renderer r render-cfg #:mode 'annotated)))
