#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt"
         "../loader.rkt"
         (only-in "../probe.rkt" make-probes))

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

  ;; Registry head: @head/名字 是代码侧片段的模块化端点，无文件参与。
  (define-config code-base [suite (introduce sealed) 'demo])
  (write-config! (build-path root "jobs" "uses-registry.config")
                 "#:extends \"@reg/code-base\"\n[label () \"reg\"]\n")
  (parameterize ([current-config-search-heads
                  (hash-set heads 'reg (hash 'code-base code-base))])
    (define c (load-config "@jobs/uses-registry"))
    (define rr (resolve c))
    (check-eq? (resolved-value rr 'suite) 'demo)
    (check-equal? (resolved-value rr 'label) "reg"))
  (check-exn #rx"undefined search head"
             (lambda () (load-config "@jobs/uses-registry")))
  ;; #:extends 只许 @head 端点与向下相对路径：裸注册表符号被拒
  (write-config! (build-path root "jobs" "bare-symbol.config")
                 "#:extends registry-base\n[label () \"reg\"]\n")
  (check-exn #rx"裸符号已禁止"
             (lambda () (load-config "@jobs/bare-symbol"))))

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

;; ---------------------------------------------------------------------------
;; provide 意图经 .config 声明

(define root3 (make-temporary-file "configkit-loader3-~a" 'directory))
(define (w3! rel text)
  (define p (build-path root3 rel))
  (make-parent-directory* p)
  (call-with-output-file p (lambda (o) (display text o))))
(w3! "jobs/pv-base.config" "[f (introduce required)]\n")
(w3! "jobs/pv.config" "#:extends \"pv-base\"\n[f (provide) 7]\n")
(w3! "jobs/pv-typo.config" "#:extends \"pv-base\"\n[ff (provide) 7]\n")
(parameterize ([current-config-search-heads (hash 'jobs (build-path root3 "jobs"))])
  (define r (resolve (load-config "@jobs/pv")))
  (check-true (resolved-ok? r) (format "~a" (resolved-issues r)))
  (check-equal? (resolved-value r 'f) 7)
  (check-true (for/or ([i (in-list (resolved-issues
                                    (resolve (load-config "@jobs/pv-typo"))))])
                (eq? (issue-kind i) 'dangling-provide))))
(delete-directory/files root3)

;; ---------------------------------------------------------------------------
;; 源位置显示跟随进入路由：直接路径 → 相对 cwd；@head 引用 → 模块化端点
;; （不泄露搜索头根目录真实位置），head 内链式 #:extends 继承别名

(define root4 (make-temporary-file "configkit-loader4-~a" 'directory))
(define (w4! rel text)
  (define p (build-path root4 rel))
  (make-parent-directory* p)
  (call-with-output-file p (lambda (o) (display text o))))
(w4! "shared/common.config"
     "[port ((validate (integer-between 1 65535))) 70000]\n")
(w4! "shared/base-config.config"
     "#:extends \"common\"\n[host () \"localhost\"]\n")
(w4! "jobs/nested/job.config"
     "#:extends \"@root/shared/base-config\"\n[host (override) \"example.com\"]\n")
(define (port-loc r)
  (for/first ([i (in-list (resolved-issues r))]
              #:when (eq? (issue-field i) 'port))
    (hash-ref (issue-data i) 'value-at)))
(define (job4-port-loc)
  (parameterize ([current-config-search-heads (hash 'root root4)])
    (port-loc (resolve (load-config-file
                        (build-path root4 "jobs/nested/job.config"))))))
;; @head 路由（含 head 内链式相对引用）：端点显示，与 cwd 无关
(parameterize ([current-directory root4])
  (check-equal? (job4-port-loc) "@root/shared/common.config:1"))
(parameterize ([current-directory (find-system-path 'home-dir)])
  (check-equal? (job4-port-loc) "@root/shared/common.config:1"))
;; 直接文件路径进入：相对 cwd 显示（链式向下引用同样按直接路径处理）
(parameterize ([current-directory root4])
  (check-equal? (port-loc (resolve (load-config-file "shared/base-config.config")))
                "shared/common.config:1"))
(delete-directory/files root4)

;; ---------------------------------------------------------------------------
;; 同文件一字段多次给值：装载不崩溃，resolve 记 duplicate-value 议题
;; （首个值行生效），应用侧经 check/诊断块输出

(define root5 (make-temporary-file "configkit-loader5-~a" 'directory))
(call-with-output-file (build-path root5 "dup.config")
  (lambda (o) (display "[x () 1]\n[x () 2]\n" o)))
(define rdup (resolve (load-config-file (build-path root5 "dup.config"))))
(check-true (for/or ([i (in-list (resolved-issues rdup))])
              (eq? (issue-kind i) 'duplicate-value)))
(check-equal? (resolved-value rdup 'x) 1)
(delete-directory/files root5)

;; ---------------------------------------------------------------------------
;; 配置笔误全部进用户态错误流程：带行号的友好错误，无裸契约异常

(define root6 (make-temporary-file "configkit-loader6-~a" 'directory))
(define (w6! rel text)
  (define p (build-path root6 rel))
  (make-parent-directory* p)
  (call-with-output-file p (lambda (o) (display text o))))
(w6! "default-empty.config"  "[x ((default))]\n")
(w6! "validate-empty.config" "[x ((validate))]\n")
(w6! "help-empty.config"     "[x ((help))]\n")
(w6! "extends-number.config" "#:extends 42\n[x () 1]\n")
(check-exn #rx"\\(default \\.\\.\\.\\) 需要一个参数"
           (lambda () (load-config-file (build-path root6 "default-empty.config"))))
(check-exn #rx"\\(validate \\.\\.\\.\\) 需要一个参数"
           (lambda () (load-config-file (build-path root6 "validate-empty.config"))))
(check-exn #rx"\\(help \\.\\.\\.\\) 需要一个参数"
           (lambda () (load-config-file (build-path root6 "help-empty.config"))))
(check-exn #rx"#:extends 需要引用字符串"
           (lambda () (load-config-file (build-path root6 "extends-number.config"))))
(delete-directory/files root6)

;; ---------------------------------------------------------------------------
;; 回归钉（自检实证）：跨头别名传播 + .config 链上的 duplicate-value 出处

(define root7a (make-temporary-file "configkit-loader7a-~a" 'directory))
(define root7b (make-temporary-file "configkit-loader7b-~a" 'directory))
(call-with-output-file (build-path root7b "deep.config")
  (lambda (o) (display "[p () 1]\n[p () 2]\n" o)))
(call-with-output-file (build-path root7a "job.config")
  (lambda (o) (display "#:extends \"@b/deep\"\n[q () 3]\n" o)))
(parameterize ([current-config-search-heads (hash 'a root7a 'b root7b)]
               [current-directory (find-system-path 'home-dir)])
  (define r (resolve (load-config "@a/job")))
  ;; 经 @b 路由的文件：议题出处回显 @b 端点，不泄真实目录、不错继承 @a
  (define d (for/first ([i (in-list (resolved-issues r))]
                        #:when (eq? (issue-kind i) 'duplicate-value)) i))
  (check-equal? (hash-ref (issue-data d) 'value-at) "@b/deep.config:1")
  ;; 自家文件按自己的进入路由（@a）显示
  (check-true (for/or ([o (in-list (provenance-ref r 'q))])
                (equal? (origin-srcloc o) "@a/job.config:2"))))
(delete-directory/files root7a)
(delete-directory/files root7b)

;; ---------------------------------------------------------------------------
;; (compute ...)：值档的闭合位置——沙箱内求值、原文入档、同轴互斥

(define root8 (make-temporary-file "configkit-loader8-~a" 'directory))
(define (write8! name text)
  (call-with-output-file (build-path root8 name) #:exists 'replace
    (lambda (o) (display text o)))
  (build-path root8 name))

;; 计算值压过基座 default，且查探测记录：单遍未就绪、复解得值
(write8! "base.config" "[copies ((default 1))]\n")
(define compute-job
  (write8! "job.config"
           (string-append "#:extends \"base\"\n"
                          "[copies (override (compute (lambda (v)"
                          " (config-probe-ref v 'cores 0))))]\n")))
(define rc0 (resolve (load-config-file compute-job)))
(check-eq? (hash-ref (unfilled-fields rc0) 'copies #f) 'awaiting-probes)
(check-equal? (resolved-issues rc0) '())
(define rc1 (resolve (load-config-file compute-job)
                     #:probes (make-probes (hash 'cores 24))))
(check-equal? (resolved-value rc1 'copies 'NONE) 24)
;; 表达式原文随值进 provenance（报告仍是无闭包数据）
(check-true (for/or ([o (in-list (provenance-ref rc1 'copies))])
              (and (eq? (origin-kind o) 'computed-value)
                   (regexp-match? #rx"config-probe-ref" (origin-info o)))))

;; 沙箱围栏对计算位同样生效（限时/限内存/无文件系统），失败是数据
(define compute-denied
  (write8! "denied.config"
           "[x ((compute (lambda (v) (if (file-exists? \"/etc/hosts\") 1 0))))]\n"))
(define rcd (resolve (load-config-file compute-denied)))
(check-true (for/or ([i (in-list (resolved-issues rcd))])
              (and (eq? (issue-kind i) 'computed-value-failed)
                   (regexp-match? #rx"access denied" (issue-message i)))))

;; 同轴互斥：值位 / removed / 同行 default，三条在装载期拦
(for ([row (in-list
            (list "[x (override (compute (lambda (v) 1))) 8]\n"
                  "[x (override (compute (lambda (v) 1)) (default 2))]\n"
                  "[x (removed (compute (lambda (v) 1)))]\n"))]
      [msg (in-list (list #rx"不得再给值位"
                          #rx"意图冲突"
                          #rx"不能与 removed 同行"))])
  (define p (write8! "bad.config" row))
  (check-exn msg (lambda () (load-config-file p))))

;; required 与 compute 同行放行：required 是需求方标记不是提供者，组合
;; 有意义——值照常算出，值被后代 removed 掩掉后 required 重新武装。
(define req-compute
  (write8! "reqc.config"
           "[x (introduce required (compute (lambda (v) 7)))]\n"))
(define rrq (resolve (load-config-file req-compute)))
(check-equal? (resolved-value rrq 'x 'NONE) 7)
(check-equal? (resolved-issues rrq) '())
(check-true (for/or ([o (in-list (provenance-ref rrq 'x))])
              (eq? (origin-kind o) 'computed-value)))
;; 同 config 拆两行写语义相同（放行前唯一的写法）
(define req-compute-2rows
  (write8! "reqc2.config"
           (string-append "[x (required)]\n"
                          "[x (provide (compute (lambda (v) 7)))]\n")))
(check-equal? (resolved-value (resolve (load-config-file req-compute-2rows)) 'x 'NONE)
              7)
;; 后代 removed 掩掉计算值 → required 重新武装（eager 档当场报）
(write8! "reqc-base.config"
         "[x (introduce required eager (compute (lambda (v) 7)))]\n")
(define req-compute-rm
  (write8! "reqc-rm.config"
           (string-append "#:extends \"reqc-base\"\n"
                          "[x (removed)]\n")))
(define rrm (resolve (load-config-file req-compute-rm)))
(check-eq? (hash-ref (unfilled-fields rrm) 'x #f) 'required)
(check-true (for/or ([i (in-list (resolved-issues rrm))])
              (eq? (issue-kind i) 'eager-required-missing)))

;; 形状判定：只收 (lambda ...)，组合子应用/字面量不适用
(check-exn #rx"只接受 \\(lambda"
           (lambda ()
             (load-config-file (write8! "shape.config" "[x ((compute 5))]\n"))))
(delete-directory/files root8)
