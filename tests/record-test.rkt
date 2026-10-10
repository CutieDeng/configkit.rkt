#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../record.rkt")

(define-config base
  [copies   ((default 2))]
  [tune     ((default "base"))]
  [hw-avail (introduce required)]
  [secret   () "never-read"])

(define-config job
  #:extends base
  [copies (override) 4])

(define r (resolve job))
(define-values (src rec) (make-recording-source r))

;; A consumer reads some fields; unfilled reads return the caller's fail value.
(check-equal? (config-source-ref src 'copies) 4)
(check-equal? (config-source-ref src 'tune) "base")
(check-equal? (config-source-ref src 'copies) 4)          ; re-read: dedup
(check-eq? (config-source-ref src 'hw-avail 'placeholder) 'placeholder)
(record-note! rec 'hw-avail "渲染为占位注释行")

;; Read set: first-read order, deduped.
(check-equal? (record-reads rec) '(copies tune hw-avail))
(check-equal? (record-unfilled rec) '(hw-avail))   ; 名单，无计数
(check-equal? (record-notes rec) '((hw-avail "渲染为占位注释行")))

;; Filled-but-never-read fields surface (the typo detector).
(check-not-false (memq 'secret (unread-fields/record r rec)))
(check-false (memq 'copies (unread-fields/record r rec)))

;; ---------------------------------------------------------------------------
;; Reports: single read-able datum, closures sanitized

;; 计算默认正常求值（无错误门控）……
(define-config with-closure
  [x ((default (lambda (v) 42)))])
(define r-ok (resolve with-closure))
(define report-ok (make-report #:function 'resolve #:resolved r-ok))
(check-eq? (hash-ref report-ok 'verdict) 'ok)
(check-equal? (hash-ref (hash-ref report-ok 'values) 'x) 42)

;; ……失败配置的报告：verdict、issues、往返
(define-config failing
  [bad ((validate (lambda (v) "总是失败"))) 1])
(define r2 (resolve failing))
(define report (make-report #:function 'resolve #:resolved r2))
(check-equal? (hash-ref report 'format-version) 2)
(check-eq? (hash-ref report 'kind) 'resolve-report)
(check-eq? (hash-ref report 'verdict) 'failed)

(define path (make-temporary-file "configkit-report-~a.rktd"))
(void (write-report report path))
(define back (with-input-from-file path read))
(check-equal? back report)                     ; 往返一致
(check-eq? (hash-ref back 'verdict) 'failed)
(check-true (for/or ([i (in-list (hash-ref back 'issues))])
              (equal? (hash-ref i 'message) "总是失败")))
(delete-file path)

;; Consumer report combines resolve data with the read record.
(define full (make-report #:function 'demo-render
                          #:resolved r #:record rec #:source r))
(check-eq? (hash-ref full 'kind) 'consumer-report)
(check-equal? (hash-ref full 'read-set) '(copies tune hw-avail))
(check-not-false (memq 'secret (hash-ref full 'unread-fields)))
(check-equal? (hash-ref full 'unfilled-reads) '(hw-avail))
;; provenance survives serialization as plain data
(define prov (hash-ref full 'provenance))
(check-true (for/or ([o (in-list (hash-ref prov 'copies))])
              (eq? (hash-ref o 'kind) 'provided)))

;; 检视意见 5c：报告 values 只含已填字段，无占位符碰撞
(define-config tricky
  [real-sym () '<unfilled>]          ; 字段值恰为该符号——不会与占位混淆
  [gap (introduce required)])
(define rt (resolve tricky))
(define tr (make-report #:function 'resolve #:resolved rt))
(check-equal? (hash-ref (hash-ref tr 'values) 'real-sym) '<unfilled>)
(check-false (hash-has-key? (hash-ref tr 'values) 'gap))
(check-true (hash-has-key? (hash-ref tr 'unfilled) 'gap))

;; id / class 进报告：'id 总在，'class 未声明时为 #f
(check-eq? (hash-ref full 'id) 'job)
(check-false (hash-ref full 'class))
(define-config classed [class () "demo"] [x () 1])
(define cr (make-report #:function 'resolve #:resolved (resolve classed)))
(check-eq? (hash-ref cr 'id) 'classed)
(check-equal? (hash-ref cr 'class) "demo")

;; ---------------------------------------------------------------------------
;; 通配读取（config-source-ref-group）与应用态标记（record-mark-read!）

(define-config fam
  [env:OMP      (introduce) "8"]
  [env:AFFINITY (introduce) "0-63"]
  [env:TRACE    (introduce required)]      ; 未填：不可枚举，通配扫不到
  [copise       (introduce) 16]
  [tune         () "base"])
(define rf (resolve fam))
(define-values (fsrc frec) (make-recording-source rf))

;; 前缀通配：已填的族内成员逐个真实 ref 入读集；未填成员不在 keys 中，
;; 不被扫掠触碰（族的完备性检查走 require-filled 后验，不走读取面）
(define envs (config-source-ref-group fsrc 'env:))
(check-equal? envs (hasheq 'env:OMP "8" 'env:AFFINITY "0-63"))
(check-equal? (sort (record-reads frec) symbol<?) '(env:AFFINITY env:OMP))
(check-equal? (record-unfilled frec) '())
;; regexp 形态等价
(check-equal? (config-source-ref-group fsrc #rx"^env:") envs)

;; 标记 = 应用声明的真实使用情形：离开未读集，理由进报告可审计
(record-mark-read! frec 'tune "运行期探测覆盖，渲染器有意不读")
(check-equal? (unread-fields/record rf frec) '(copise))
(check-equal? (record-marks frec) '((tune "运行期探测覆盖，渲染器有意不读")))
(define fr (make-report #:function 'sweep #:resolved rf #:record frec #:source rf))
(check-equal? (hash-ref fr 'marks) '((tune "运行期探测覆盖，渲染器有意不读")))
(check-equal? (hash-ref fr 'unread-fields) '(copise))
;; env:TRACE 的"缺"由求解面暴露，与读取面无关
(check-eq? (hash-ref (hash-ref fr 'unfilled) 'env:TRACE) 'required)

;; ---------------------------------------------------------------------------
;; consume/record：一调用完成生产消费循环（静默；debug-consume 是其打印外壳）

(define-values (cv creport)
  (consume/record rf
    (lambda (src rec)
      (record-mark-read! rec 'tune "有意不读")
      (config-source-ref src 'env:OMP))
    #:function 'render))
(check-equal? cv "8")
(check-eq? (hash-ref creport 'kind) 'consumer-report)
(check-eq? (hash-ref creport 'function) 'render)
(check-equal? (hash-ref creport 'read-set) '(env:OMP))
(check-equal? (hash-ref creport 'marks) '((tune "有意不读")))
;; 未求解的 config 也可直接喂入（内部代为 resolve）；一元 proc 亦可
(define-values (cv2 creport2)
  (consume/record fam (lambda (src) (config-source-ref src 'copise))))
(check-equal? cv2 16)
(check-eq? (hash-ref creport2 'function) 'consume)

;; ---------------------------------------------------------------------------
;; 消费期旗标（record-flag!）：使用值时发现问题，现场标注；缺省警告级

(record-flag! frec 'env:OMP "本机只有 4 核，8 线程将超订")   ; 缺省 warning
(record-flag! frec 'copise "渲染器无法识别该字段" #:severity 'error)
(check-equal? (record-flags frec)
              '((env:OMP warning "本机只有 4 核，8 线程将超订")
                (copise error "渲染器无法识别该字段")))
;; 严重度只有 warning/error 两级
(check-exn exn:fail:contract?
           (lambda () (record-flag! frec 'x "y" #:severity 'fatal)))
;; 进报告：'flags 键，往返可 read
(define fr2 (make-report #:function 'sweep #:resolved rf #:record frec #:source rf))
(check-equal? (hash-ref fr2 'flags)
              '((env:OMP warning "本机只有 4 核，8 线程将超订")
                (copise error "渲染器无法识别该字段")))
