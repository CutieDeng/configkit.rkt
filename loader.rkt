#lang racket

;; The .config loader (configkit/README.md §3).  A .config file is data with
;; two lambda-shaped holes: loading reads it with read-syntax and parses the
;; config forms directly — no module expansion, no #lang.  Only the closed
;; positions ((validate ...) / (validate/post ...) / (default <procedure>))
;; are evaluated, inside a racket/sandbox evaluator; every later call of such
;; a closure re-enters the sandbox context, so its security guard and limits
;; apply at call time, not only at load time.
;;
;; Reference forms for #:extends and load-config:
;;   "sub/path"        downward from the referencing file's own directory
;;   "@head/sub/path"  downward from a host-defined (possibly fake) root
;;   a symbol          a host-registered code config (no file is loaded)
;; No "..", no absolute paths, upward unreachable.

(require racket/sandbox
         "config.rkt"
         "validators.rkt"
         (only-in "probe.rkt" config-probe-ref)
         (only-in "source.rkt" config-source-ref))

(provide current-config-search-heads
         current-config-registry
         load-config
         load-config-file)

;; Host-held tables; not configuration data (self-privilege-escalation guard).
(define current-config-search-heads (make-parameter (hash)))
(define current-config-registry (make-parameter (hash)))

(define config-extension ".config")

;; In-progress files, for cycle detection.
(define currently-loading (make-parameter '()))

;; ---------------------------------------------------------------------------
;; Reference resolution

(define (split-reference who ref)
  ;; "a/b/c" -> (list "a" "b" "c"), validated: no "", no ".", no "..".
  ;; #:trim? #f keeps empty components, so absolute paths ("/etc/x" ->
  ;; ("" "etc" "x")) and doubled slashes are caught by the "" check below
  ;; instead of being silently normalized into relative references.
  (define parts (string-split ref "/" #:trim? #f))
  (when (null? parts)
    (raise-arguments-error who "empty reference" "reference" ref))
  (for ([p (in-list parts)])
    (when (member p '("" "." ".."))
      (raise-arguments-error who
                             "reference must be a plain downward path"
                             "reference" ref)))
  parts)

;; Resolve symlinks along every existing component (bounded per component to
;; break link cycles); components that do not exist yet are appended as-is.
(define (fully-resolve p)
  (define parts (explode-path (simplify-path (path->complete-path p) #f)))
  (for/fold ([cur (car parts)]) ([comp (in-list (cdr parts))])
    (define next (build-path cur comp))
    (let loop ([q next] [fuel 40])
      (cond
        [(zero? fuel) q]
        [(link-exists? q)
         (define target (resolve-path q))
         (define-values (dir _f _d) (split-path q))
         (loop (simplify-path (path->complete-path target dir) #f)
               (sub1 fuel))]
        [else q]))))

(define (under-root? root path)
  (define rs (path->string root))
  (string-prefix? (path->string path)
                  (if (string-suffix? rs "/") rs (string-append rs "/"))))

(define (contained-path who root parts)
  ;; Two-stage containment: the path itself (lexical), then the
  ;; filesystem-resolved path (symlinks followed) — both must stay inside
  ;; the (equally resolved) root.
  ;; 引用可写可不写 .config 后缀："base" 与 "base.config" 指同一个文件
  (define leaf (if (string-suffix? (last parts) config-extension)
                   (last parts)
                   (string-append (last parts) config-extension)))
  (define joined
    (apply build-path root (append (drop-right parts 1) (list leaf))))
  (define simplified (simplify-path (path->complete-path joined) #f))
  (define root* (simplify-path (path->complete-path root) #f))
  (unless (under-root? root* simplified)
    (raise-arguments-error who "reference escapes its root"
                           "reference" (string-join parts "/")
                           "root" (path->string root*)))
  (define resolved (fully-resolve simplified))
  (define root-resolved (fully-resolve root*))
  (unless (under-root? root-resolved resolved)
    (raise-arguments-error who
                           "reference escapes its root after symlink resolution"
                           "reference" (string-join parts "/")
                           "resolved" (path->string resolved)
                           "root" (path->string root-resolved)))
  simplified)

(define (resolve-reference who ref base-dir)
  ;; -> (values 'file path alias) | (values 'registry config #f)
  ;; alias: (cons root "@head")，@head 引用的显示别名；其余 #f
  (cond
    [(symbol? ref)
     (define c (hash-ref (current-config-registry) ref #f))
     (unless c
       (raise-arguments-error who "unknown registry reference" "reference" ref))
     (values 'registry c #f)]
    [(and (string? ref) (string-prefix? ref "@"))
     (define parts (split-reference who (substring ref 1)))
     (define head (string->symbol (car parts)))
     (when (null? (cdr parts))
       (raise-arguments-error who "head reference names no file" "reference" ref))
     (define root (hash-ref (current-config-search-heads) head #f))
     (unless root
       (raise-arguments-error who "undefined search head"
                              "head" head "reference" ref))
     (cond
       ;; 头映射到注册表（符号 → 代码侧片段）：@head/名字 即模块化端点
       [(hash? root)
        (unless (null? (cddr parts))
          (raise-arguments-error who "registry head takes a single name"
                                 "reference" ref))
        (define c (hash-ref root (string->symbol (cadr parts)) #f))
        (unless c
          (raise-arguments-error who "unknown name under registry head"
                                 "reference" ref
                                 "known" (sort (hash-keys root) symbol<?)))
        (values 'registry c #f)]
       [else
        (values 'file (contained-path who root (cdr parts))
                (cons (simplify-path (path->complete-path root) #f)
                      (format "@~a" head)))])]
    [(string? ref)
     (unless base-dir
       (raise-arguments-error who
                              "a relative reference needs a referencing file"
                              "reference" ref))
     (values 'file (contained-path who base-dir (split-reference who ref)) #f)]
    [else (raise-argument-error who "string or symbol reference" ref)]))

;; ---------------------------------------------------------------------------
;; Sandbox for the closed positions

;; Framework interface visible inside .config closed positions: the query
;; surface, the verdict constructors, and the validator combinators.
(define sandbox-bindings
  (list (cons 'config-source-ref config-source-ref)
        (cons 'config-env-ref config-env-ref)
        (cons 'fail fail)
        (cons 'warn warn)
        (cons 'skip skip)
        (cons 'one-of one-of)
        (cons 'number-between number-between)
        (cons 'integer-between integer-between)
        (cons 'nonempty-string nonempty-string)
        (cons 'string-matching string-matching)
        (cons 'list-where list-where)
        (cons 'all-of all-of)
        (cons 'require-filled require-filled)
        (cons 'warn-unfilled warn-unfilled)
        (cons 'require-known require-known)
        (cons 'warn-unknown warn-unknown)
        (cons 'config-probe-ref config-probe-ref)))

(define (make-config-evaluator)
  (parameterize ([sandbox-output 'string]
                 [sandbox-error-output 'string]
                 [sandbox-memory-limit 64]
                 [sandbox-eval-limits '(5 32)])
    (make-evaluator 'racket/base)))

(define (sandboxed-closure ev datum srcloc)
  ;; Evaluate the lambda inside the sandbox; wrap so every call re-enters the
  ;; sandbox context (guard + limits at call time).
  (define proc
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-arguments-error
                        'load-config
                        "closed-position expression rejected by the sandbox"
                        "at" srcloc
                        "cause" (exn-message e)))])
      (ev datum)))
  (unless (procedure? proc)
    (raise-arguments-error 'load-config
                           "closed position must evaluate to a procedure"
                           "at" srcloc))
  (lambda (arg)
    (call-in-sandbox-context ev (lambda () (proc arg)))))

;; ---------------------------------------------------------------------------
;; Parsing

;; 源位置的显示路径跟随进入路由：直接以文件路径进入的配置，显示相对
;; 当前目录的路径；经 @head 模块化引用进入的，回显引用端点（@head/…）
;; ——不暴露搜索头根目录的真实位置，防信息泄露与抽象泄露。别名在引用
;; 解析时设定，随加载的动态范围传播，同一 head 内的链式 #:extends 继承
;; 模块化显示。仅词法化简，不改写符号链接。
(define current-source-alias (make-parameter #f)) ; (cons root-path "@head")

(define (display-path p)
  (define abs (simplify-path (path->complete-path p) #f))
  (define alias (current-source-alias))
  (if (and alias (under-root? (car alias) abs))
      (format "~a/~a" (cdr alias)
              (path->string (find-relative-path (car alias) abs)))
      (path->string (find-relative-path (current-directory) abs))))

(define (stx-loc stx)
  (format "~a:~a"
          (let ([src (syntax-source stx)])
            (if (path? src) (display-path src) (format "~a" src)))
          (or (syntax-line stx) "?")))

(define (datum-value who stx)
  ;; Value positions carry data literals only.
  (define d (syntax->datum stx))
  (let check ([v d])
    (cond
      [(boolean? v)
       (raise-arguments-error who
                              "布尔字面量请写 true/false（#t/#f 保留给框架层）"
                              "at" (stx-loc stx))]
      [(or (number? v) (string? v) (symbol? v) (null? v)) (void)]
      [(pair? v) (check (car v)) (check (cdr v))]
      [else (raise-arguments-error who
                                   "value positions in .config carry data literals only"
                                   "at" (stx-loc stx) "given" v)]))
  (normalize-value d))

(define (parse-config-props who ev props-stx)
  ;; -> (values flags default compute validators help)
  (define flags '())
  (define default #f)
  (define compute #f)   ; (cons proc source-text) | #f
  (define validators '())
  (define help #f)
  ;; 带参属性的参数位：缺参是配置笔误，给带行号的用户态错误，
  ;; 不许裸 cadr 契约异常漏出。
  (define (prop-payload p what)
    (define xs (syntax->list p))
    (unless (and xs (pair? (cdr xs)))
      (raise-arguments-error who (format "(~a ...) 需要一个参数" what)
                             "at" (stx-loc p)))
    (cadr xs))
  (for ([p (in-list (syntax->list props-stx))])
    (define d (syntax->datum p))
    (cond
      [(memq d '(introduce provide override sealed required eager removed
                 multi-introducer env))
       (set! flags (cons d flags))]
      [(and (pair? d) (eq? (car d) 'compute))
       ;; 计算值：值档的提供者，闭合位置，与 (default <lambda>) 同一沙箱、
       ;; 同一形状判定（只收 (lambda ...)，组合子应用不适用）。表达式原文
       ;; 随值进 provenance——代码产出的值与手写的值一样可审。
       (define payload (prop-payload p 'compute))
       (define datum (syntax->datum payload))
       (unless (and (pair? datum) (eq? (car datum) 'lambda))
         (raise-arguments-error who "(compute ...) 只接受 (lambda ...)"
                                "at" (stx-loc p)))
       (set! compute (cons (sandboxed-closure ev datum (stx-loc p))
                           (source-text datum)))]
      [(and (pair? d) (eq? (car d) 'default))
       (define payload (prop-payload p 'default))
       (set! default
             (present
              (if (and (pair? (syntax->datum payload))
                       (eq? (car (syntax->datum payload)) 'lambda))
                  (sandboxed-closure ev (syntax->datum payload) (stx-loc p))
                  (datum-value who payload))))]
      [(and (pair? d) (memq (car d) '(validate validate/post)))
       (define payload (prop-payload p (car d)))
       (set! validators
             (cons (vdecl (if (eq? (car d) 'validate) 'immediate 'post)
                          (sandboxed-closure ev (syntax->datum payload)
                                             (stx-loc p))
                          (stx-loc p))
                   validators))]
      [(and (pair? d) (eq? (car d) 'probe))
       ;; Probers are trusted host code running outside the sandbox; a
       ;; .config file must not supply them.
       (raise-arguments-error who
                              "(probe ...) 仅限代码侧配置（探测器是宿主受信代码，不经沙箱）"
                              "at" (stx-loc p))]
      [(and (pair? d) (eq? (car d) 'help))
       (define s (syntax->datum (prop-payload p 'help)))
       (unless (string? s)
         (raise-arguments-error who "(help ...) takes a string literal"
                                "at" (stx-loc p)))
       (set! help s)]
      [else
       (raise-arguments-error who "unknown property in .config"
                              "at" (stx-loc p) "property" d)]))
  (values flags default compute (reverse validators) help))

;; 表达式原文，超长截断——报告要能读，不要能撑爆。
(define (source-text datum)
  (define t (format "~s" datum))
  (if (> (string-length t) 200) (string-append (substring t 0 197) "...") t))

(define (parse-config-file who path)
  ;; -> (values parent-ref global-validators rows)  rows: (cons field entry)
  (define stxes
    (call-with-input-file path
      (lambda (in)
        (port-count-lines! in)
        (let loop ([acc '()])
          (define stx (read-syntax path in))
          (if (eof-object? stx) (reverse acc) (loop (cons stx acc)))))))
  (define ev (make-config-evaluator))
  (call-in-sandbox-context
   ev
   (lambda ()
     (for ([binding (in-list sandbox-bindings)])
       (namespace-set-variable-value! (car binding) (cdr binding)))))
  (define parent-ref #f)
  (define globals '())
  (define rows '())
  (let loop ([xs stxes])
    (cond
      [(null? xs) (void)]
      [(eq? (syntax-e (car xs)) '#:extends)
       (when parent-ref
         (raise-arguments-error who "at most one #:extends" "file" path))
       (when (null? (cdr xs))
         (raise-arguments-error who "#:extends needs a reference" "file" path))
       (define ref (syntax->datum (cadr xs)))
       ;; 引用只有两种合法形态；笔误在解析现场按行号报出
       (cond
         [(symbol? ref)
          (raise-arguments-error
           who
           "#:extends 裸符号已禁止；写模块化绝对路径 \"@head/名字\" 或向下相对路径"
           "given" ref "at" (stx-loc (cadr xs)))]
         [(not (string? ref))
          (raise-arguments-error
           who
           "#:extends 需要引用字符串：\"@head/名字\" 或向下相对路径"
           "given" ref "at" (stx-loc (cadr xs)))])
       (set! parent-ref ref)
       (loop (cddr xs))]
      [(eq? (syntax-e (car xs)) '#:validate/post)
       (when (null? (cdr xs))
         (raise-arguments-error who "#:validate/post needs an expression"
                                "file" path))
       (set! globals
             (cons (vdecl 'post
                          (sandboxed-closure ev (syntax->datum (cadr xs))
                                             (stx-loc (cadr xs)))
                          (stx-loc (cadr xs)))
                   globals))
       (loop (cddr xs))]
      [else
       (define row (syntax->list (car xs)))
       (unless (and row (<= 2 (length row) 3) (identifier? (car row)))
         (raise-arguments-error who
                                "expected [field (property ...) value?]"
                                "at" (stx-loc (car xs))))
       (define field (syntax-e (car row)))
       (define props (cadr row))
       (unless (syntax->list props)
         (raise-arguments-error who
                                "the property group must be a parenthesized list"
                                "at" (stx-loc (car xs))))
       (define-values (flags default compute validators help)
         (parse-config-props who ev props))
       (define value
         (and (= (length row) 3)
              (present (datum-value who (caddr row)))))
       ;; compute 是提供者：与值位、removed 同轴互斥；与同行 default 同写
       ;; 意图冲突（计算值走值档，同行默认值永不生效）。跨配置的祖先
       ;; default 被压是格的正常结果，不在此拦。
       ;;
       ;; required 同行放行，理由见 config.rkt 同名检查处：required 是
       ;; 需求方标记不是提供者，拆两行写一直合法且语义相同；值档被后代
       ;; removed 掩掉后 required 重新武装。
       (when compute
         (when value
           (raise-arguments-error who "(compute ...) 行不得再给值位"
                                  "at" (stx-loc (car xs))))
         (when (memq 'removed flags)
           (raise-arguments-error who
                                  "(compute ...) 不能与 removed 同行"
                                  "at" (stx-loc (car xs))))
         (when default
           (raise-arguments-error
            who
            "(compute ...) 与同行 (default ...) 意图冲突：计算值走值档，默认值永不生效"
            "at" (stx-loc (car xs)))))
       (define perm
         (let ([p (filter (lambda (f) (memq f '(introduce provide override))) flags)])
           (if (null? p) '(introduce provide override) p)))
       (when (and value (or (memq 'required flags) (memq 'removed flags)))
         (raise-arguments-error who
                                "required/removed rows must not give a value"
                                "at" (stx-loc (car xs))))
       (set! rows
             (cons (cons field
                         (make-entry #:perm perm
                                     #:multi? (and (memq 'multi-introducer flags) #t)
                                     #:sealed? (and (memq 'sealed flags) #t)
                                     #:required? (and (memq 'required flags) #t)
                                     #:eager? (and (memq 'eager flags) #t)
                                     #:removed? (and (memq 'removed flags) #t)
                                     #:env? (and (memq 'env flags) #t)
                                     #:value (if compute
                                                 (present (computed (car compute)
                                                                    (cdr compute)))
                                                 value)
                                     #:default default
                                     #:validators validators
                                     #:help help
                                     #:srcloc (stx-loc (car xs))))
                   rows))
       (loop (cdr xs))]))
  (values parent-ref (reverse globals) (reverse rows)))

;; ---------------------------------------------------------------------------
;; Loading

(define (load-config-file path)
  ;; Host-trusted direct entry (tests, tooling); .config references inside the
  ;; file are confined to downward relative paths and @head endpoints (a head
  ;; maps to a directory or a registry namespace); bare registry symbols are
  ;; host-API-only and forbidden in .config.
  (define complete (simplify-path (path->complete-path path) #f))
  (when (member complete (currently-loading))
    (raise-arguments-error 'load-config "cyclic #:extends"
                           "file" (path->string complete)))
  (define-values (dir file _dir?) (split-path complete))
  (define name
    (string->symbol (regexp-replace #rx"\\.config$" (path->string file) "")))
  (define-values (parent-ref globals rows)
    (parameterize ([currently-loading (cons complete (currently-loading))])
      (parse-config-file 'load-config complete)))
  (define parent
    (and parent-ref
         (parameterize ([currently-loading (cons complete (currently-loading))])
           (load-reference 'load-config parent-ref dir))))
  (make-config-object name (display-path complete) parent rows globals))

(define (load-reference who ref base-dir)
  (define-values (kind target alias) (resolve-reference who ref base-dir))
  (case kind
    [(registry) target]
    [(file)
     (unless (file-exists? target)
       (raise-arguments-error who "referenced .config does not exist"
                              "path" (path->string target)))
     ;; 无别名的（向下相对）引用不重置参数：head 内的链式引用继承别名
     (if alias
         (parameterize ([current-source-alias alias]) (load-config-file target))
         (load-config-file target))]))

(define (load-config ref)
  ;; Host entry: "@head/sub" or a registry symbol; a bare relative string has
  ;; no referencing file to anchor to and is rejected.
  (load-reference 'load-config ref #f))
