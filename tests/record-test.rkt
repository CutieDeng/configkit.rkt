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
(check-equal? (hash-ref (record-unfilled rec) 'hw-avail) 1)
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
(check-equal? (hash-ref report 'format-version) 1)
(check-eq? (hash-ref report 'kind) 'resolve-report)
(check-eq? (hash-ref report 'verdict) 'failed)

(define path (make-temporary-file "configkit-report-~a.rktd"))
(write-report report path)
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
(check-equal? (hash-ref (hash-ref full 'unfilled-reads) 'hw-avail) 1)
;; provenance survives serialization as plain data
(define prov (hash-ref full 'provenance))
(check-true (for/or ([o (in-list (hash-ref prov 'copies))])
              (eq? (hash-ref o 'kind) 'provided)))
