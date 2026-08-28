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

(define (contained-path who root parts)
  ;; Join and double-check containment after simplification.
  (define joined
    (apply build-path root (append (drop-right parts 1)
                                   (list (string-append (last parts)
                                                        config-extension)))))
  (define simplified (simplify-path (path->complete-path joined) #f))
  (define root* (simplify-path (path->complete-path root) #f))
  (define rs (path->string root*))
  (define ss (path->string simplified))
  (unless (string-prefix? ss (if (string-suffix? rs "/") rs (string-append rs "/")))
    (raise-arguments-error who "reference escapes its root"
                           "reference" (string-join parts "/")
                           "root" rs))
  simplified)

(define (resolve-reference who ref base-dir)
  ;; -> (values 'file path) | (values 'registry config)
  (cond
    [(symbol? ref)
     (define c (hash-ref (current-config-registry) ref #f))
     (unless c
       (raise-arguments-error who "unknown registry reference" "reference" ref))
     (values 'registry c)]
    [(and (string? ref) (string-prefix? ref "@"))
     (define parts (split-reference who (substring ref 1)))
     (define head (string->symbol (car parts)))
     (when (null? (cdr parts))
       (raise-arguments-error who "head reference names no file" "reference" ref))
     (define root (hash-ref (current-config-search-heads) head #f))
     (unless root
       (raise-arguments-error who "undefined search head"
                              "head" head "reference" ref))
     (values 'file (contained-path who root (cdr parts)))]
    [(string? ref)
     (unless base-dir
       (raise-arguments-error who
                              "a relative reference needs a referencing file"
                              "reference" ref))
     (values 'file (contained-path who base-dir (split-reference who ref)))]
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
        (cons 'warn-unfilled warn-unfilled)))

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

(define (stx-loc stx)
  (format "~a:~a"
          (let ([src (syntax-source stx)])
            (if (path? src)
                (let-values ([(_b f _d) (split-path src)]) (path->string f))
                (format "~a" src)))
          (or (syntax-line stx) "?")))

(define (datum-value who stx)
  ;; Value positions carry data literals only.
  (define d (syntax->datum stx))
  (let check ([v d])
    (cond
      [(or (number? v) (string? v) (symbol? v) (boolean? v) (null? v)) (void)]
      [(pair? v) (check (car v)) (check (cdr v))]
      [else (raise-arguments-error who
                                   "value positions in .config carry data literals only"
                                   "at" (stx-loc stx) "given" v)]))
  (normalize-value d))

(define (parse-config-props who ev props-stx)
  ;; -> (values flags default validators probe help)
  (define flags '())
  (define default #f)
  (define validators '())
  (for ([p (in-list (syntax->list props-stx))])
    (define d (syntax->datum p))
    (cond
      [(memq d '(introduce override sealed required eager removed
                 multi-introducer env))
       (set! flags (cons d flags))]
      [(and (pair? d) (eq? (car d) 'default))
       (define payload (cadr (syntax->list p)))
       (set! default
             (present
              (if (and (pair? (syntax->datum payload))
                       (eq? (car (syntax->datum payload)) 'lambda))
                  (sandboxed-closure ev (syntax->datum payload) (stx-loc p))
                  (datum-value who payload))))]
      [(and (pair? d) (memq (car d) '(validate validate/post)))
       (define payload (cadr (syntax->list p)))
       (set! validators
             (cons (vdecl (if (eq? (car d) 'validate) 'immediate 'post)
                          (sandboxed-closure ev (syntax->datum payload)
                                             (stx-loc p))
                          (stx-loc p))
                   validators))]
      [else
       (raise-arguments-error who "unknown property in .config"
                              "at" (stx-loc p) "property" d)]))
  (values flags default (reverse validators)))

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
       (set! parent-ref (syntax->datum (cadr xs)))
       (loop (cddr xs))]
      [(eq? (syntax-e (car xs)) '#:validate/post)
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
       (define-values (flags default validators)
         (parse-config-props who ev props))
       (define value
         (and (= (length row) 3)
              (present (datum-value who (caddr row)))))
       (define perm
         (let ([p (filter (lambda (f) (memq f '(introduce override))) flags)])
           (if (null? p) '(introduce override) p)))
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
                                     #:value value
                                     #:default default
                                     #:validators validators
                                     #:srcloc (stx-loc (car xs))))
                   rows))
       (loop (cdr xs))]))
  (values parent-ref (reverse globals) (reverse rows)))

;; ---------------------------------------------------------------------------
;; Loading

(define (load-config-file path)
  ;; Host-trusted direct entry (tests, tooling); .config references inside the
  ;; file are still confined to downward/@head/registry.
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
  (make-config-object name (path->string complete) parent rows globals))

(define (load-reference who ref base-dir)
  (define-values (kind target) (resolve-reference who ref base-dir))
  (case kind
    [(registry) target]
    [(file)
     (unless (file-exists? target)
       (raise-arguments-error who "referenced .config does not exist"
                              "path" (path->string target)))
     (load-config-file target)]))

(define (load-config ref)
  ;; Host entry: "@head/sub" or a registry symbol; a bare relative string has
  ;; no referencing file to anchor to and is rejected.
  (load-reference 'load-config ref #f))
