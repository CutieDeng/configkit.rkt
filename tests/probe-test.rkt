#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../probe.rkt"
         "../record.rkt"
         "../loader.rkt"
         racket/file)

;; ---------------------------------------------------------------------------
;; 探测判定：未填 ∧ 有探测器。无标记值——显式值压过探测，removed 重开探测。

(define (probe-ncpus r) 8)
(define (probe-label) "auto-label")            ; 零元探测器
(define (probe-broken r) (error "gcc not found"))

(define-config hw-base
  [ncpus   (introduce (probe probe-ncpus))]
  [label   (introduce (probe probe-label))]
  [gcc-ver (introduce (probe probe-broken))]
  [plain   (introduce required)]               ; 无探测器
  [copies  ((default 2))])

(define r (resolve hw-base))

;; 内核只携带探测器，resolve 不执行（保持纯）
(check-equal? (sort (hash-keys (resolved-probers r)) symbol<?)
              '(gcc-ver label ncpus))
(check-eq? (resolved-value r 'ncpus 'absent) 'absent)

(define pr (probe-fields r))
(check-true (probe-record? pr))
(check-equal? (probe-record-fields pr) '(label ncpus))
(check-equal? (probe-ref pr 'ncpus) 8)
(check-equal? (probe-ref pr 'label) "auto-label")

;; 失败降级为记录条目，不中断，其余字段照探
(define fs (probe-record-failures pr))
(check-equal? (length fs) 1)
(check-eq? (probe-failure-field (car fs)) 'gcc-ver)
(check-regexp-match #rx"gcc not found" (probe-failure-reason (car fs)))

;; 条目携带时刻与探测器标识
(define e (hash-ref (probe-record-entries pr) 'ncpus))
(check-eq? (probe-entry-prober e) 'probe-ncpus)
(check-true (> (probe-entry-at e) 0))

;; 显式值压过探测：填了的字段不进探测
(define-config hw-set #:extends hw-base [ncpus () 4] [plain () "x"])
(define r2 (resolve hw-set))
(check-false (hash-has-key? (probe-record-entries (probe-fields r2)) 'ncpus))
;; removed 掩值 → 回到未填 → 重新可探
(define-config hw-reopen #:extends hw-set [ncpus (removed)])
(check-equal? (probe-ref (probe-fields (resolve hw-reopen)) 'ncpus) 8)

;; 一元探测器收 resolved，可读其他字段
(define (probe-2x r) (* 2 (resolved-value r 'copies)))
(define-config derived-probe
  [copies  ((default 3))]
  [build-n (introduce (probe probe-2x))])
(check-equal? (probe-ref (probe-fields (resolve derived-probe)) 'build-n) 6)

;; 链内近端探测器压过远端（同 entry 合并方向）
(define (probe-a r) 'a)
(define (probe-b r) 'b)
(define-config shadow-base [f (introduce (probe probe-a))])
(define-config shadow-leaf #:extends shadow-base [f ((probe probe-b))])
(check-eq? (probe-ref (probe-fields (resolve shadow-leaf)) 'f) 'b)

;; ---------------------------------------------------------------------------
;; 注入与函数式更新

(define fake (make-probes (hash 'ncpus 64 'label "fake")))
(check-equal? (probe-ref fake 'ncpus) 64)
(check-eq? (probe-entry-prober (hash-ref (probe-record-entries fake) 'ncpus))
           'injected)

;; 半真半假：真跑后改一个，原记录不变
(define half (probes-set pr 'ncpus 128 #:prober 'test))
(check-equal? (probe-ref half 'ncpus) 128)
(check-equal? (probe-ref half 'label) "auto-label")
(check-equal? (probe-ref pr 'ncpus) 8)

;; probe-ref 的 fail 三形态与 config-source-ref 同契约
(check-eq? (probe-ref pr 'nope 'absent) 'absent)
(check-equal? (probe-ref pr 'nope (lambda () 9)) 9)
(check-eq? (probe-ref pr 'nope) source-missing)

;; ---------------------------------------------------------------------------
;; with-probes：探测值走普通 ref 路径，消费者免改

(define src (with-probes r pr))
(check-equal? (config-source-ref src 'copies) 2)             ; 已填原样
(check-equal? (config-source-ref src 'ncpus) 8)              ; 未填 → 探测值
(check-eq? (config-source-ref src 'plain 'absent) 'absent)   ; 无探 → fail 路径
(check-eq? (config-source-ref src 'gcc-ver 'absent) 'absent) ; 探测失败仍未填
(check-not-false (memq 'ncpus (config-source-keys src)))     ; keys 并入探测字段

;; recording 在外层：读集反映消费者，值由探测供给，不算未填读取
(define-values (rsrc rec) (make-recording-source src))
(check-equal? (config-source-ref rsrc 'ncpus) 8)
(check-eq? (config-source-ref rsrc 'plain 'ph) 'ph)
(check-equal? (record-reads rec) '(ncpus plain))
(check-equal? (record-unfilled rec) '(plain))

;; ---------------------------------------------------------------------------
;; 后验验证器 = 环境求值器：resolve #:probes 注入，config-probe-ref 查询

(define (probe-cores r) 4)
(define-config env-checked
  [host-cores (introduce (probe probe-cores))]
  [copies ((default 8)
           (validate/post
            (lambda (cfg)
              (define cores (config-probe-ref cfg 'host-cores 'unknown))
              (cond [(eq? cores 'unknown) (skip #:reason "无探测记录，放行")]
                    [(<= (config-source-ref cfg 'copies) cores) #t]
                    [else (fail #:reason "copies 超出宿主核数"
                                #:expected cores
                                #:given (config-source-ref cfg 'copies))]))))])

;; 无记录：验证器自决跳过
(define re0 (resolve env-checked))
(check-true (resolved-ok? re0) (format "~a" (resolved-issues re0)))
(check-equal? (length (resolved-skipped re0)) 1)

;; 两段式：纯求解 → 实探 → 带记录复解，环境检查生效（8 > 4）
(define re1 (resolve env-checked #:probes (probe-fields re0)))
(check-false (resolved-ok? re1))
(check-true (for/or ([i (in-list (resolved-issues re1))])
              (eq? (issue-field i) 'copies)))

;; 注入宽裕的假记录放行
(check-true (resolved-ok?
             (resolve env-checked #:probes (make-probes (hash 'host-cores 16)))))

;; 查询被感知：config-probe-ref 的查询入名单（首查序、含未命中），进报告
(check-equal? (resolved-probe-reads re0) '((host-cores #f)))   ; 无记录 → 未命中
(check-equal? (resolved-probe-reads re1) '((host-cores #t)))
(define rep-q (make-report #:function 'resolve #:resolved re1))
(check-equal? (hash-ref rep-q 'probe-reads) '(host-cores))
(check-equal? (hash-ref rep-q 'probe-misses) '())
(check-equal? (hash-ref (make-report #:function 'resolve #:resolved re0)
                        'probe-misses)
              '(host-cores))

;; 纯半段（计算默认）不得查探测：view 上调用即契约错，降级为记录条目
(define-config probe-in-computed
  [x ((default (lambda (v) (config-probe-ref v 'k 0))))])
(define rpc (resolve probe-in-computed))
(check-true (for/or ([i (in-list (resolved-issues rpc))])
              (and (eq? (issue-kind i) 'computed-default-failed)
                   (regexp-match? #rx"config-probe-ref" (issue-message i)))))

;; ---------------------------------------------------------------------------
;; 报告接线：'probes / 'probe-failures，format-version 2，往返

(define rep (make-report #:function 'probe-run #:resolved r #:probes pr))
(check-equal? (hash-ref rep 'format-version) 2)
(define pv (hash-ref (hash-ref rep 'probes) 'ncpus))
(check-equal? (hash-ref pv 'value) 8)
(check-eq? (hash-ref pv 'prober) 'probe-ncpus)
(check-eq? (hash-ref (car (hash-ref rep 'probe-failures)) 'field) 'gcc-ver)
(define path (make-temporary-file "configkit-probe-~a.rktd"))
(write-report rep path)
(check-equal? (with-input-from-file path read) rep)
(delete-file path)

;; ---------------------------------------------------------------------------
;; loader：(probe ...) 仅代码侧，(help ...) 支持

(define root (make-temporary-file "configkit-probe-loader-~a" 'directory))
(define (w! rel text)
  (define p (build-path root rel))
  (make-parent-directory* p)
  (call-with-output-file p (lambda (o) (display text o))))
(w! "jobs/has-probe.config" "[x ((probe (lambda (r) 1)))]\n")
(w! "jobs/has-help.config" "[x ((help \"副本数\") (default 2))]\n")
(w! "jobs/bad-help.config" "[x ((help 3))]\n")
(w! "jobs/probe-query.config"
    (string-append "[y () 1]\n"
                   "#:validate/post (lambda (cfg)\n"
                   "  (begin (config-probe-ref cfg 'host-cores 'none) #t))\n"))
(parameterize ([current-config-search-heads (hash 'jobs (build-path root "jobs"))])
  (check-exn #rx"仅限代码侧" (lambda () (load-config "@jobs/has-probe")))
  (check-equal? (resolved-value (resolve (load-config "@jobs/has-help")) 'x) 2)
  (check-exn #rx"string literal" (lambda () (load-config "@jobs/bad-help")))
  ;; 沙箱验证器的探测查询同样被感知
  (define rq (resolve (load-config "@jobs/probe-query")
                      #:probes (make-probes (hash 'host-cores 8))))
  (check-true (resolved-ok? rq) (format "~a" (resolved-issues rq)))
  (check-equal? (resolved-probe-reads rq) '((host-cores #t))))
(delete-directory/files root)
