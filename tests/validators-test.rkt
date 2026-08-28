#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../loader.rkt"
         "../validators.rkt")

(define (has-issue? r kind [field #f])
  (for/or ([i (in-list (resolved-issues r))])
    (and (eq? (issue-kind i) kind)
         (or (not field) (eq? (issue-field i) field)))))
(define (issue-msg r field)
  (for/first ([i (in-list (resolved-issues r))]
              #:when (eq? (issue-field i) field))
    (issue-message i)))

;; ---------------------------------------------------------------------------
;; Direct calls: verdict shapes

(check-eq? ((one-of "txt" "csv") "txt") #t)
(let ([v ((one-of "txt" "csv") "pdf")])
  (check-true (verdict-fail? v))
  (check-equal? (verdict-fail-given v) "pdf")
  (check-equal? (verdict-fail-expected v) '("txt" "csv")))

(check-eq? ((number-between 1 8) 4) #t)
(check-true (verdict-fail? ((number-between 1 8) 9)))
(check-true (verdict-fail? ((number-between 1 8) "4")))
(check-eq? ((integer-between 1 8) 4) #t)
(check-true (verdict-fail? ((integer-between 1 8) 4.5)))

(check-eq? (nonempty-string "x") #t)
(check-true (verdict-fail? (nonempty-string "")))
(check-true (verdict-fail? (nonempty-string 3)))

(check-eq? ((string-matching #px"^[a-z-]+$") "intrate") #t)
(check-true (verdict-fail? ((string-matching #px"^[a-z-]+$") "Int Rate")))

(check-eq? ((list-where exact-positive-integer?) '(1 2 3)) #t)
(let ([v ((list-where exact-positive-integer?) '(1 -2 3 "x"))])
  (check-true (list? v))
  (check-equal? (length v) 2))
(check-true (verdict-fail? ((list-where exact-positive-integer?) 5)))

(let ([v ((all-of nonempty-string (string-matching #px"^[a-z]+$")) "")])
  ;; 两个子检查的裁决按列表协议逐条累积
  (check-true (list? v))
  (check-equal? (length v) 2))

;; ---------------------------------------------------------------------------
;; In configs (.rkt side)

(define-config base
  [output-format ((default "txt") (validate (one-of "txt" "csv" "cfg")))]
  [copies        ((default 1) (validate (integer-between 1 8)))]
  [runlist       ((validate (all-of nonempty-string
                                    (string-matching #px"^[a-z,]+$"))))]
  [hw-avail      (introduce required)]
  [sw-avail      (introduce required)])

(define ok (resolve (config base (hash 'runlist "intrate" 'copies 4))))
(check-true (resolved-ok? ok) (format "~a" (resolved-issues ok)))

(define bad (resolve (config base (hash 'output-format "pdf" 'runlist "OK!"))))
(check-true (has-issue? bad 'validator-failed 'output-format))
(check-equal? (issue-msg bad 'output-format) "不在枚举集内")
(check-true (has-issue? bad 'validator-failed 'runlist))

;; require-filled / warn-unfilled：无初始化值的快速检查（后验）
(define-config hardened
  #:extends base
  #:validate/post (require-filled 'hw-avail 'sw-avail)
  [runlist () "intrate"]
  [hw-avail () "Jun-2026"])

(define rh (resolve hardened))
(check-false (resolved-ok? rh))
(check-true (for/or ([i (in-list (resolved-issues rh))])
              (and (equal? (issue-message i) "字段无初始化值")
                   (eq? (hash-ref (issue-data i) 'given) 'sw-avail))))

(define-config soft
  #:extends base
  #:validate/post (warn-unfilled 'hw-avail 'sw-avail)
  [runlist () "intrate"])

(define rs (resolve soft))
(check-true (resolved-ok? rs))
(check-equal? (length (resolved-warnings rs)) 2)

;; ---------------------------------------------------------------------------
;; require-known / warn-unknown：族内字段名白名单（require-filled 的反方向）

(define-config env-job
  [env:OMP_NUM_THREADS   (introduce) "8"]
  [env:GOMP_CPU_AFFINITY (introduce) "0-63"]
  [env:OMP_NUM_THREAD    (introduce) "4"]     ; 拼错的族成员
  [copies () 2])                              ; 族外字段不受检查

;; 应用态快速门：一个只带全局后验的守卫 config，并列组合即生效
(define-config env-guard
  #:validate/post (require-known 'env:
                                 'env:OMP_NUM_THREADS 'env:GOMP_CPU_AFFINITY))
(define rk (resolve (config env-job env-guard)))
(check-false (resolved-ok? rk))
(define ki (car (resolved-issues rk)))
(check-equal? (issue-message ki) "族内出现不支持的字段")
(check-eq? (hash-ref (issue-data ki) 'given) 'env:OMP_NUM_THREAD)
(check-regexp-match #rx"是否想要 env:OMP_NUM_THREADS"
                    (hash-ref (issue-data ki) 'hint))
(check-regexp-match #rx"不支持的字段" (explain-resolved rk))

;; warn 版：不阻断，逐条入警告
(define-config env-guard/soft
  #:validate/post (warn-unknown 'env:
                                'env:OMP_NUM_THREADS 'env:GOMP_CPU_AFFINITY))
(define rw (resolve (config env-job env-guard/soft)))
(check-true (resolved-ok? rw))
(check-equal? (length (resolved-warnings rw)) 1)
(check-regexp-match #rx"env:OMP_NUM_THREAD 不受支持；是否想要"
                    (issue-message (car (resolved-warnings rw))))

;; 全员合法 → 通过；regexp 形态等价
(define-config env-clean
  [env:OMP_NUM_THREADS (introduce) "8"] [copies () 2])
(check-true (resolved-ok? (resolve (config env-clean env-guard))))
(define-config env-guard/rx
  #:validate/post (require-known #rx"^env:" 'env:OMP_NUM_THREADS))
(check-true (resolved-ok? (resolve (config env-clean env-guard/rx))))

;; ---------------------------------------------------------------------------
;; In .config files: combinators available inside the sandbox, no lambda

(define root (make-temporary-file "configkit-validators-~a" 'directory))
(make-directory* (build-path root "jobs"))
(call-with-output-file (build-path root "jobs" "checked.config")
  (lambda (o)
    (display #<<EOF
[output-format ((validate (one-of "txt" "csv"))) "pdf"]
[copies        ((validate (integer-between 1 8))) 4]
EOF
             o)))
(call-with-output-file (build-path root "jobs" "env-family.config")
  (lambda (o)
    (display #<<EOF
#:validate/post (require-known "env:" 'env:OMP_NUM_THREADS)
[env:OMP_NUM_THREADS (introduce) "8"]
[env:BOGUS (introduce) "1"]
EOF
             o)))
(parameterize ([current-config-search-heads (hash 'jobs (build-path root "jobs"))])
  (define c (load-config "@jobs/checked"))
  (define r (resolve c))
  (check-true (has-issue? r 'validator-failed 'output-format))
  (check-equal? (issue-msg r 'output-format) "不在枚举集内")
  (check-false (has-issue? r 'validator-failed 'copies))
  ;; 族白名单也可在 .config 内自声明（沙箱注入）
  (define rf (resolve (load-config "@jobs/env-family")))
  (check-false (resolved-ok? rf))
  (check-eq? (hash-ref (issue-data (car (resolved-issues rf))) 'given) 'env:BOGUS))
(delete-directory/files root)

;; ---------------------------------------------------------------------------
;; 调测增强：did-you-mean、类型不符、失败归因、explain

(require "../record.rkt")

;; 编辑距离建议
(let ([v ((one-of "txt" "csv" "cfg") "cvs")])
  (check-true (verdict-fail? v))
  (check-equal? (verdict-fail-hint v) "是否想要 \"csv\"？"))
;; 距离过远则无建议
(check-false (verdict-fail-hint ((one-of "txt" "csv") "postscript")))
;; 类型不符（符号 vs 字符串）优先于编辑距离
(let ([v ((one-of "txt" "csv") 'txt)])
  (check-regexp-match #rx"类型不符" (verdict-fail-hint v)))

;; 失败归因：issue data 携带验证器声明位与值的 provenance
(define-config attr-base
  [output-format ((validate (one-of "txt" "csv" "cfg")))])
(define-config attr-job
  #:extends attr-base
  [output-format () "cvs"])
(define ra (resolve attr-job))
(define ai (car (resolved-issues ra)))
(check-eq? (issue-field ai) 'output-format)
(let ([d (issue-data ai)])
  (check-regexp-match #rx"validators-test" (hash-ref d 'validator-at))
  (check-eq? (hash-ref d 'value-from) 'attr-job)
  (check-regexp-match #rx"validators-test" (hash-ref d 'value-at))
  (check-equal? (hash-ref d 'hint) "是否想要 \"csv\"？"))

;; explain：一键人类可读展开
(define text (explain-resolved ra))
(check-regexp-match #rx"错误 \\(1\\)" text)
(check-regexp-match #rx"output-format: 不在枚举集内" text)
(check-regexp-match #rx"是否想要" text)
(check-regexp-match #rx"值来自:   attr-job" text)
(check-regexp-match #rx"验证器于" text)
;; 未填（noneager）如实列出——explain 是同一数据的展开视图
(check-regexp-match #rx"未填字段" (explain-resolved (resolve attr-base)))
;; 真正干净的求解 → 无异常
(define-config attr-clean #:extends attr-base [output-format () "csv"])
(check-equal? (explain-resolved (resolve attr-clean)) "无异常\n")
