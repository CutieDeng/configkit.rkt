#lang racket

(require (except-in rackunit fail)
         "../main.rkt")

(define-config base
  [copies   ((default 2))]
  [tune     ((default "base"))]
  [hw-avail (introduce required)]
  [ghost    () "unread"])

(define-config job #:extends base [copies (override) 4])

;; resolve-summary / check-config
(define s (resolve-summary job))
(check-true (hash-ref s 'ok?))
(check-equal? (hash-ref s 'errors) 0)
(check-equal? (hash-ref s 'unfilled) 1)

(define sink (open-output-string))
(check-true (check-config job #:out sink))
(check-equal? (get-output-string sink) "")          ; 健康时静默

(define-config broken [x (override) 1])
(define sink2 (open-output-string))
(check-false (check-config broken #:out sink2))
(check-regexp-match #rx"错误" (get-output-string sink2))

;; peek / peek-field 打印且返回 resolved
(define sink3 (open-output-string))
(define r (peek job #:out sink3))
(check-true (resolved? r))
(check-regexp-match #rx"copies = 4" (get-output-string sink3))
(define sink4 (open-output-string))
(void (peek-field job 'copies #:out sink4))
(check-regexp-match #rx"provided" (get-output-string sink4))
(check-regexp-match #rx"overridden|default-yielded" (get-output-string sink4))

;; debug-consume：消费者开发回路
(define sink5 (open-output-string))
(define-values (result report)
  (debug-consume job
                 (lambda (src)
                   (list (config-source-ref src 'copies)
                         (config-source-ref src 'hw-avail 'placeholder)))
                 #:function 'mini-render
                 #:out sink5))
(check-equal? result '(4 placeholder))
(check-regexp-match #rx"读集: \\(copies hw-avail\\)" (get-output-string sink5))
(check-regexp-match #rx"未填读取" (get-output-string sink5))
(check-regexp-match #rx"未读字段" (get-output-string sink5))
(check-not-false (memq 'ghost (hash-ref report 'unread-fields)))
(check-eq? (hash-ref report 'function) 'mini-render)

;; list-configs：头表核对
(define root (make-temporary-file "configkit-debug-~a" 'directory))
(make-directory* (build-path root "jobs" "sub"))
(call-with-output-file (build-path root "jobs" "a.config")
  (lambda (o) (display "[x () 1]\n" o)))
(call-with-output-file (build-path root "jobs" "sub" "b.config")
  (lambda (o) (display "[y () 2]\n" o)))
(define listing (list-configs #:heads (hash 'jobs (build-path root "jobs")
                                            'nowhere (build-path root "absent"))))
(check-equal? (hash-ref listing 'jobs) '("@jobs/a" "@jobs/sub/b"))
(check-eq? (hash-ref listing 'nowhere) 'missing-root)

;; dump-report
(define rp (build-path root "r.rktd"))
(void (dump-report job rp))
(check-eq? (hash-ref (with-input-from-file rp read) 'verdict) 'ok)
(delete-directory/files root)
