#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../loader.rkt")

(define (write-config! path text)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display text out))
    #:exists 'truncate/replace))

(define root (make-temporary-file "configkit-loader-~a" 'directory))

;; Tree:
;;   site/template.config
;;   site/nested/extra.config
;;   jobs/nightly.config          extends @site/template
;;   jobs/sub/child.config        extends parent via downward? (no: upward is out)
;;   jobs/evil.config             extends "../secret"  -> rejected
;;   jobs/evil-abs.config         extends "/etc/x"     -> rejected
;;   secret.config                outside every head sub-root scope test

(write-config! (build-path root "site" "template.config")
  #<<EOF
[output-parent (sealed) "/srv/spec/runs"]
[tune ((default "base"))]
[copies ((validate (lambda (n) (or (<= n 64) "copies 超上限")))) 2]
[relax (env (default false))]
EOF
  )

(write-config! (build-path root "jobs" "nightly.config")
  #<<EOF
#:extends "@site/template"
[spec-src () "/opt/cpu2026"]
[copies (override) 4]
[flag () true]
[build-ncpus ((default (lambda (v) (* 2 (config-source-ref v 'copies)))))]
EOF
  )

(write-config! (build-path root "jobs" "sub" "child.config")
  #<<EOF
[iterations () 3]
EOF
  )

(write-config! (build-path root "jobs" "with-child.config")
  #<<EOF
#:extends "sub/child"
[label () "with-child"]
EOF
  )

(write-config! (build-path root "jobs" "evil.config")
  #<<EOF
#:extends "../site/template"
EOF
  )

(write-config! (build-path root "jobs" "evil-abs.config")
  #<<EOF
#:extends "/etc/passwd"
EOF
  )

(write-config! (build-path root "jobs" "sneaky.config")
  #<<EOF
[x ((validate (lambda (v) (delete-file "/tmp/should-not-happen") #t))) 1]
EOF
  )

(write-config! (build-path root "jobs" "toplevel-code.config")
  #<<EOF
(displayln "should not run")
[x () 1]
EOF
  )

(write-config! (build-path root "loop" "a.config") "#:extends \"b\"\n[x () 1]\n")
(write-config! (build-path root "loop" "b.config") "#:extends \"a\"\n[y () 2]\n")

(define heads (hash 'site (build-path root "site")
                    'jobs (build-path root "jobs")))

(parameterize ([current-config-search-heads heads])

  ;; @head resolution + chain through extends + boolean/closed positions.
  (define nightly (load-config "@jobs/nightly"))
  (check-true (config-object? nightly))
  (define r (resolve nightly))
  (check-true (resolved-ok? r) (format "~a" (resolved-issues r)))
  (check-eq? (resolved-id r) 'nightly)          ; .config 的 id 即文件名
  (check-equal? (resolved-value r 'copies) 4)
  (check-equal? (resolved-value r 'output-parent) "/srv/spec/runs")
  (check-eq? (resolved-value r 'flag) #t)              ; true 归一化
  (check-equal? (resolved-value r 'build-ncpus) 8)     ; 沙箱计算默认可读配置
  (check-equal? (resolved-value r 'tune) "base")

  ;; Chain validator from the .config runs (sandboxed) and fails on bad data.
  (define bad (resolve (config nightly (hash 'copies 128))))
  (check-true (for/or ([i (in-list (resolved-issues bad))])
                (eq? (issue-kind i) 'unification-conflict))) ; 128 vs 4 先冲突

  ;; Downward reference from a file's own directory.
  (define with-child (load-config "@jobs/with-child"))
  (define rc (resolve with-child))
  (check-equal? (resolved-value rc 'iterations) 3)
  (check-equal? (resolved-value rc 'label) "with-child")

  ;; Upward and absolute references are rejected.
  (check-exn #rx"plain downward path"
             (lambda () (load-config "@jobs/evil")))
  (check-exn #rx"plain downward path|reference escapes"
             (lambda () (load-config "@jobs/evil-abs")))

  ;; Unknown head; bare relative at host entry; missing file.
  (check-exn #rx"undefined search head"
             (lambda () (load-config "@nowhere/x")))
  (check-exn #rx"relative reference needs a referencing file"
             (lambda () (load-config "site/template")))
  (check-exn #rx"does not exist"
             (lambda () (load-config "@jobs/absent")))

  ;; Top-level code in a .config is a parse error, not an execution.
  (check-exn #rx"property group|expected \\[field"
             (lambda () (load-config "@jobs/toplevel-code")))

  ;; Cyclic extends.
  (parameterize ([current-config-search-heads
                  (hash 'loop (build-path root "loop"))])
    (check-exn #rx"cyclic" (lambda () (load-config "@loop/a"))))

  ;; Sandbox: filesystem access from a .config closure is denied at call time.
  (define sneaky (load-config "@jobs/sneaky"))
  (define rs (resolve sneaky))
  (check-true (for/or ([i (in-list (resolved-issues rs))])
                (eq? (issue-kind i) 'validator-failed))
              "沙箱应拒绝文件系统访问，验证器以异常失败")
  (check-false (file-exists? "/tmp/should-not-happen"))

  ;; Registry reference: no file involved.
  (define-config code-base [suite (introduce sealed) 'demo])
  (write-config! (build-path root "jobs" "uses-registry.config")
                 "#:extends registry-base\n[label () \"reg\"]\n")
  (parameterize ([current-config-registry (hash 'registry-base code-base)])
    (define c (load-config "@jobs/uses-registry"))
    (define rr (resolve c))
    (check-eq? (resolved-value rr 'suite) 'demo)
    (check-equal? (resolved-value rr 'label) "reg"))
  (check-exn #rx"unknown registry reference"
             (lambda () (load-config "@jobs/uses-registry"))))

;; A lambda-shaped list in value position is inert data, never a closure:
;; value positions are read, not evaluated.
(write-config! (build-path root "jobs" "code-value.config")
               "[x () (lambda (v) v)]\n")
(parameterize ([current-config-search-heads heads])
  (define c (load-config "@jobs/code-value"))
  (define rv (resolved-value (resolve c) 'x))
  (check-false (procedure? rv))
  (check-equal? rv '(lambda (v) v)))

(delete-directory/files root)

;; ---------------------------------------------------------------------------
;; 检视意见回归（loader）

(define root2 (make-temporary-file "configkit-loader2-~a" 'directory))
(define (w2! rel text)
  (define p (build-path root2 rel))
  (make-parent-directory* p)
  (call-with-output-file p (lambda (o) (display text o))))

;; 5a) #:validate/post 缺表达式 → 友好报错
(w2! "jobs/no-payload.config" "#:validate/post\n")
;; 5b) 原始布尔字面量被拒
(w2! "jobs/raw-bool.config" "[flag () #t]\n")
;; 4) 符号链接逃逸：根内目录链接指向根外
(w2! "outside/secret.config" "[leak () 1]\n")
(make-file-or-directory-link (build-path root2 "outside")
                             (build-path root2 "jobs" "link"))

(parameterize ([current-config-search-heads (hash 'jobs (build-path root2 "jobs"))])
  (check-exn #rx"#:validate/post needs an expression"
             (lambda () (load-config "@jobs/no-payload")))
  (check-exn #rx"true/false"
             (lambda () (load-config "@jobs/raw-bool")))
  ;; 词法检查（一段）通过，文件系统解析（二段）拦截
  (check-exn #rx"symlink resolution"
             (lambda () (load-config "@jobs/link/secret"))))

(delete-directory/files root2)
