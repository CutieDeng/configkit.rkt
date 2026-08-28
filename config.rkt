#lang racket

;; The config kernel: partial records with per-field declaration axes,
;; order-independent merging, provenance, and the resolve pipeline
;; (docs/config-refactor.md §3.2, docs/config-examples.md §1).
;;
;; A config is a named partial record.  Configs compose two ways: extension
;; (#:extends, a directed reference forming inheritance chains) and parallel
;; composition ((config a b ...), unordered).  resolve merges a composition
;; into a full record plus per-field provenance, accumulating issues instead
;; of failing on the first.

(require racket/generic
         (for-syntax racket/base racket/syntax syntax/parse)
         "source.rkt")

(provide define-config
         config
         config-object?
         ;; construction surface for the loader (library-internal by convention)
         make-config-object
         make-entry
         present
         normalize-value
         resolve
         resolved?
         resolved-ok?
         resolved-issues
         resolved-warnings
         resolved-values
         resolved-value
         resolved-skipped
         unfilled-fields
         inoperative-declarations
         provenance-ref
         config-env-ref
         ;; verdict constructors and predicates
         fail warn skip
         verdict-fail? verdict-warn? verdict-skip?
         verdict-fail-reason verdict-fail-expected verdict-fail-given verdict-fail-hint
         verdict-warn-reason verdict-skip-reason
         (struct-out vdecl)
         ;; issue introspection
         (struct-out issue)
         (struct-out origin))

;; ---------------------------------------------------------------------------
;; Data

;; A value slot: distinguishes "no value" (#f slot) from any present value,
;; including the boolean #f itself.
(struct present (v) #:transparent)

;; One field row.  perm is a non-empty subset of '(introduce override).
(struct entry
  (perm multi? sealed? required? eager? removed? env?
   value        ; (present v) | #f
   default      ; (present datum-or-procedure) | #f ; procedure = computed
   validators   ; (listof vdecl)
   probe        ; procedure | #f  (host probing; not run by resolve)
   help
   srcloc)
  #:transparent)

(struct vdecl (kind proc srcloc) #:transparent) ; kind: 'immediate | 'post

;; A config object: identity, one optional parent (inheritance chain edge),
;; field entries, and config-level posterior validators.
(struct config-object (name srcloc parent entries global-validators)
  #:transparent)

;; Parallel composition node.
(struct config-par (parts) #:transparent)

;; Diagnostics.
(struct issue (kind field message data) #:transparent)
(struct origin (kind config-name srcloc info) #:transparent)

;; Validator verdicts (rich protocol, docs/config-examples.md §1.4).
(struct verdict-fail (reason expected given hint) #:transparent)
(struct verdict-warn (reason) #:transparent)
(struct verdict-skip (reason) #:transparent)

(define (fail #:reason reason #:expected [expected #f]
              #:given [given #f] #:hint [hint #f])
  (verdict-fail reason expected given hint))
(define (warn #:reason reason) (verdict-warn reason))
(define (skip #:reason reason) (verdict-skip reason))

;; ---------------------------------------------------------------------------
;; Construction helpers

;; Config-layer booleans are written true/false; the framework boundary
;; normalizes them.  #t/#f never appear in config files.
(define (normalize-value v)
  (cond
    [(eq? v 'true) #t]
    [(eq? v 'false) #f]
    [else v]))

(define (make-entry #:perm [perm '(introduce override)]
                    #:multi? [multi? #f]
                    #:sealed? [sealed? #f]
                    #:required? [required? #f]
                    #:eager? [eager? #f]
                    #:removed? [removed? #f]
                    #:env? [env? #f]
                    #:value [value #f]
                    #:default [default #f]
                    #:validators [validators '()]
                    #:probe [probe #f]
                    #:help [help #f]
                    #:srcloc [srcloc #f])
  (entry perm multi? sealed? required? eager? removed? env?
         value default validators probe help srcloc))

(define (hash->config h [name (gensym 'config-)])
  ;; Bare data coerced to an anonymous config: every entry takes the most
  ;; permissive declaration; provenance degrades to config granularity.
  (config-object
   name #f #f
   (for/hash ([(k v) (in-hash h)])
     (values k (list (make-entry #:multi? #t
                                 #:value (present (normalize-value v))))))
   '()))

(define (->config part who)
  (cond
    [(config-object? part) part]
    [(config-par? part) part]
    [(hash? part) (hash->config part)]
    [else (raise-argument-error who "config, composition, or hash" part)]))

(define (config . parts)
  (config-par (for/list ([part (in-list parts)]) (->config part 'config))))

;; ---------------------------------------------------------------------------
;; define-config

(define (make-config-object name srcloc parent rows global-validators)
  (define parent*
    (cond [(not parent) #f]
          [(config-object? parent) parent]
          [(hash? parent) (hash->config parent)]
          [else (raise-argument-error 'define-config
                                      "config or hash for #:extends" parent)]))
  (define entries
    (for/fold ([h (hasheq)]) ([r (in-list rows)])
      (hash-update h (car r)
                   (lambda (es) (append es (list (cdr r))))
                   '())))
  (for ([(f es) (in-hash entries)])
    (when (> (for/sum ([e (in-list es)]) (if (entry-value e) 1 0)) 1)
      (raise-arguments-error 'define-config
                             "same config gives a field more than one value"
                             "field" f "config" name)))
  (config-object name srcloc parent* entries global-validators))

(begin-for-syntax
  (define (stx-srcloc stx)
    (define src (syntax-source stx))
    (define file
      (cond [(path? src)
             (define-values (_b f _d) (split-path src))
             (path->string f)]
            [else (format "~a" src)]))
    (format "~a:~a" file (or (syntax-line stx) "?")))

  ;; Parse one property form; returns (values kind payload-stx).
  (define (parse-prop p)
    (define d (syntax->datum p))
    (cond
      [(memq d '(introduce override sealed required eager removed
                 multi-introducer env))
       (values d #f)]
      [(and (pair? d) (memq (car d) '(default validate validate/post probe help)))
       (values (car d) (cadr (syntax->list p)))]
      [else (raise-syntax-error 'define-config "unknown property" p)]))

  ;; Parse a row [field (prop ...) value?]; returns syntax building
  ;; (cons 'field <entry-expr>).
  (define (parse-row row-stx)
    (define parts (syntax->list row-stx))
    (unless (and parts (<= 2 (length parts) 3))
      (raise-syntax-error 'define-config
                          "expected [field (property ...) value?]" row-stx))
    (define field (car parts))
    (define props-stx (syntax->list (cadr parts)))
    (unless props-stx
      (raise-syntax-error 'define-config
                          "the property group must be a parenthesized (possibly empty) list"
                          (cadr parts)))
    (define value (and (= (length parts) 3) (caddr parts)))
    (define flags '())
    (define default-e #f)
    (define validators '())
    (define probe-e #f)
    (define help-e #f)
    (for ([p (in-list props-stx)])
      (define-values (kind payload) (parse-prop p))
      (case kind
        [(default) (set! default-e payload)]
        [(validate)
         (set! validators (cons #`(vdecl 'immediate #,payload
                                          #,(stx-srcloc p))
                                validators))]
        [(validate/post)
         (set! validators (cons #`(vdecl 'post #,payload #,(stx-srcloc p))
                                validators))]
        [(probe) (set! probe-e payload)]
        [(help) (set! help-e payload)]
        [else (set! flags (cons kind flags))]))
    (define perm
      (let ([p (filter (lambda (f) (memq f '(introduce override))) flags)])
        (if (null? p) ''(introduce override) #`'#,p)))
    (when (and value (or (memq 'required flags) (memq 'removed flags)))
      (raise-syntax-error 'define-config
                          "required/removed rows must not give a value" row-stx))
    #`(cons '#,field
            (make-entry #:perm #,perm
                        #:multi? #,(and (memq 'multi-introducer flags) #t)
                        #:sealed? #,(and (memq 'sealed flags) #t)
                        #:required? #,(and (memq 'required flags) #t)
                        #:eager? #,(and (memq 'eager flags) #t)
                        #:removed? #,(and (memq 'removed flags) #t)
                        #:env? #,(and (memq 'env flags) #t)
                        #:value #,(if value
                                      #`(present (normalize-value #,value))
                                      #'#f)
                        #:default #,(if default-e
                                        #`(present (normalize-value #,default-e))
                                        #'#f)
                        #:validators (list #,@(reverse validators))
                        #:probe #,(or probe-e #'#f)
                        #:help #,(or help-e #'#f)
                        #:srcloc #,(stx-srcloc row-stx)))))

(define-syntax (define-config stx)
  (define parts (syntax->list stx))
  (unless (and parts (>= (length parts) 2))
    (raise-syntax-error 'define-config "expected (define-config name clause ...)" stx))
  (define name (cadr parts))
  (unless (identifier? name)
    (raise-syntax-error 'define-config "expected an identifier" name))
  (define parent-e #f)
  (define explicit-name-e #f)
  (define globals '())
  (define rows '())
  (let loop ([clauses (cddr parts)])
    (cond
      [(null? clauses) (void)]
      [(eq? (syntax-e (car clauses)) '#:extends)
       (when (null? (cdr clauses))
         (raise-syntax-error 'define-config "#:extends needs an expression" stx))
       (set! parent-e (cadr clauses))
       (loop (cddr clauses))]
      [(eq? (syntax-e (car clauses)) '#:name)
       (set! explicit-name-e (cadr clauses))
       (loop (cddr clauses))]
      [(eq? (syntax-e (car clauses)) '#:validate/post)
       (set! globals (cons #`(vdecl 'post #,(cadr clauses)
                                    #,(stx-srcloc (cadr clauses)))
                           globals))
       (loop (cddr clauses))]
      [else
       (set! rows (cons (parse-row (car clauses)) rows))
       (loop (cdr clauses))]))
  #`(define #,name
      (make-config-object #,(or explicit-name-e #`'#,name)
                          #,(stx-srcloc stx)
                          #,(or parent-e #'#f)
                          (list #,@(reverse rows))
                          (list #,@(reverse globals)))))

;; ---------------------------------------------------------------------------
;; Resolve
;;
;; Terminology: "providers" of a field are configs whose operative entry
;; carries a value.  Along a chain the most-derived valid provider wins;
;; across independent (incomparable) configs the multiplicity axis and
;; unification decide.

(define (chain-ancestors node)
  ;; Strict ancestors, nearest first.
  (let loop ([n (config-object-parent node)] [acc '()])
    (if n (loop (config-object-parent n) (cons n acc)) (reverse acc))))

(define (ancestor-of? a b)
  ;; Is a a strict ancestor of b?
  (and (config-object? a) (config-object? b)
       (let loop ([n (config-object-parent b)])
         (cond [(not n) #f]
               [(eq? n a) #t]
               [else (loop (config-object-parent n))]))))

(define (all-nodes composition)
  ;; Every distinct config reachable (parallel parts and chain parents).
  (define seen (make-hasheq))
  (define ordered '())
  (define (visit! n)
    (cond
      [(config-par? n) (for-each visit! (config-par-parts n))]
      [(config-object? n)
       (unless (hash-ref seen n #f)
         (hash-set! seen n #t)
         (set! ordered (cons n ordered))
         (when (config-object-parent n) (visit! (config-object-parent n))))]))
  (visit! composition)
  (reverse ordered))

(define (entries-of node field)
  (hash-ref (config-object-entries node) field '()))

(define (merged-entry node field)
  ;; Same config, same field, multiple rows: union of properties, at most one
  ;; value (checked at construction).
  (define es (entries-of node field))
  (and (pair? es)
       (for/fold ([acc (car es)]) ([e (in-list (cdr es))])
         (entry (remove-duplicates (append (entry-perm acc) (entry-perm e)))
                (or (entry-multi? acc) (entry-multi? e))
                (or (entry-sealed? acc) (entry-sealed? e))
                (or (entry-required? acc) (entry-required? e))
                (or (entry-eager? acc) (entry-eager? e))
                (or (entry-removed? acc) (entry-removed? e))
                (or (entry-env? acc) (entry-env? e))
                (or (entry-value acc) (entry-value e))
                (or (entry-default acc) (entry-default e))
                (append (entry-validators acc) (entry-validators e))
                (or (entry-probe acc) (entry-probe e))
                (or (entry-help acc) (entry-help e))
                (entry-srcloc acc)))))

(define (node-ref nodes field)
  ;; (listof (cons node merged-entry)) for nodes touching field.
  (for*/list ([n (in-list nodes)]
              [e (in-value (merged-entry n field))]
              #:when e)
    (cons n e)))

(struct resolved
  (values        ; hash field -> present
    origins      ; hash field -> (listof origin), root-first
    unfilled     ; hash field -> reason symbol
    env-fields   ; seteq of field names
    issues       ; (listof issue), errors only
    warnings     ; (listof issue), never blocking
    skipped      ; (listof (list field kind srcloc reason))
    explicit)    ; seteq of fields with a non-default provider
  #:transparent
  #:methods gen:config-source
  [(define (config-source-suite r)
     (define v (hash-ref (resolved-values r) 'suite #f))
     (if v (present-v v) 'unknown))
   (define (config-source-ref r key [fail-result source-missing])
     (define v (hash-ref (resolved-values r) key #f))
     (cond [v (present-v v)]
           [(procedure? fail-result) (fail-result)]
           [else fail-result]))
   (define (config-source-explicit? r key)
     (set-member? (resolved-explicit r) key))
   (define (config-source-keys r)
     (hash-keys (resolved-values r)))])

(define (resolved-ok? r) (null? (resolved-issues r)))

(define (resolved-value r field [fail-result source-missing])
  (config-source-ref r field fail-result))

(define (unfilled-fields r) (resolved-unfilled r))

(define (inoperative-declarations r)
  (for*/list ([(field os) (in-hash (resolved-origins r))]
              [o (in-list os)]
              #:when (eq? (origin-kind o) 'introduce-inoperative))
    (list field (origin-config-name o) (origin-srcloc o) (origin-info o))))

(define (provenance-ref r field)
  (hash-ref (resolved-origins r) field '()))

(define (config-env-ref r field [fail-result source-missing])
  (unless (set-member? (resolved-env-fields r) field)
    (raise-arguments-error 'config-env-ref
                           "field is not exported to the validation environment"
                           "field" field))
  (config-source-ref r field fail-result))

;; --- verdict interpretation ------------------------------------------------

(define (apply-verdict! result field kind srcloc add-issue! add-warning! add-skip!)
  (let loop ([v result])
    (cond
      [(or (eq? v #t) (void? v)) (void)]
      [(eq? v #f)
       (add-issue! (issue 'validator-failed field "invalid value" (hasheq)))]
      [(string? v)
       (add-issue! (issue 'validator-failed field v (hasheq)))]
      [(verdict-fail? v)
       (add-issue! (issue 'validator-failed field (verdict-fail-reason v)
                          (hasheq 'expected (verdict-fail-expected v)
                                  'given (verdict-fail-given v)
                                  'hint (verdict-fail-hint v))))]
      [(verdict-warn? v)
       (add-warning! (issue 'validator-warning field (verdict-warn-reason v)
                            (hasheq)))]
      [(verdict-skip? v)
       (if (eq? kind 'post)
           (add-skip! (list field kind srcloc (verdict-skip-reason v)))
           (add-issue! (issue 'validator-failed field
                              "skip is only meaningful for posterior validators"
                              (hasheq))))]
      [(list? v) (for-each loop v)]
      [else (void)])))

(define (call-validator proc arg)
  ;; Closures originating from .config run sandboxed at the #lang layer; the
  ;; kernel confines all validators to a fresh custodian, mirroring the
  ;; existing call-controlled-callback pattern.
  (define cust (make-custodian))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian cust])
        (with-handlers ([exn:fail? (lambda (e) (fail #:reason (exn-message e)))])
          (proc arg))))
    (lambda () (custodian-shutdown-all cust))))

;; --- the pipeline ----------------------------------------------------------

(define (resolve composition)
  (define nodes (all-nodes (->config composition 'resolve)))
  (define issues '())      ; errors: gate the pipeline stage by stage
  (define warnings '())    ; collected throughout, never gating
  (define skipped '())
  (define (add-issue! i) (set! issues (cons i issues)))
  (define (add-warning! i) (set! warnings (cons i warnings)))
  (define (add-skip! s) (set! skipped (cons s skipped)))
  (define (stage-clean?) (null? issues))

  (define fields
    (sort (remove-duplicates
           (for*/list ([n (in-list nodes)]
                       [k (in-hash-keys (config-object-entries n))])
             k))
          symbol<?))

  ;; Phase: merge (unification + axis checks + eager), per field.
  (define values-out (make-hasheq))
  (define origins-out (make-hasheq))
  (define unfilled-out (make-hasheq))
  (define env-set (mutable-seteq))
  (define explicit-set (mutable-seteq))
  (define post-validators '())   ; (list field vdecl)
  (define immediate-validators '())

  (for ([field (in-list fields)])
    (define touching (node-ref nodes field))
    (define origins '())
    (define (add-origin! kind node e info)
      (set! origins (cons (origin kind (config-object-name node)
                                  (entry-srcloc e) info)
                          origins)))

    ;; Collect flags and validators from every touching entry.
    (define multi?
      (for/or ([ne (in-list touching)]) (entry-multi? (cdr ne))))
    (define eager?
      (for/or ([ne (in-list touching)]) (entry-eager? (cdr ne))))
    (define required?
      (for/or ([ne (in-list touching)]) (entry-required? (cdr ne))))
    (when (for/or ([ne (in-list touching)]) (entry-env? (cdr ne)))
      (set-add! env-set field))
    (for ([ne (in-list touching)])
      (for ([vd (in-list (entry-validators (cdr ne)))])
        (if (eq? (vdecl-kind vd) 'post)
            (set! post-validators (cons (list field vd) post-validators))
            (set! immediate-validators
                  (cons (list field vd) immediate-validators)))))

    ;; Removal: a removed entry masks value providers among its strict
    ;; ancestors (defaults survive: removal falls back to the base default).
    (define removers
      (for/list ([ne (in-list touching)] #:when (entry-removed? (cdr ne)))
        (car ne)))
    (for ([ne (in-list touching)] #:when (entry-removed? (cdr ne)))
      (add-origin! 'removed (car ne) (cdr ne) #f))

    (define (masked? node)
      (for/or ([r (in-list removers)]) (ancestor-of? node r)))

    ;; Operative value providers.
    (define providers
      (for/fold ([acc '()])
                ([ne (in-list touching)])
        (define node (car ne))
        (define e (cdr ne))
        (cond
          [(not (entry-value e)) acc]
          [(masked? node)
           (add-origin! 'masked-by-removal node e #f)
           acc]
          [else
           ;; Chain context: the nearest strict-ancestor provider.
           (define ancestor-provider
             (for*/first ([anc (in-list (reverse (chain-ancestors node)))]
                          [ae (in-value (merged-entry anc field))]
                          #:when (and ae (entry-value ae)
                                      (not (masked? anc))))
               (cons anc ae)))
           ;; An ancestor default also legitimizes override: the spec names
           ;; "链内提供者或 schema 默认值" as valid override targets.
           (define ancestor-default?
             (for*/or ([anc (in-list (chain-ancestors node))]
                       [ae (in-value (merged-entry anc field))])
               (and ae (entry-default ae) #t)))
           (define perm (entry-perm e))
           (cond
             [(and ancestor-provider (not (memq 'override perm)))
              ;; Chain re-introduction: inoperative, recorded, no issue.
              (add-origin! 'introduce-inoperative node e
                           (format "链内已有提供者: ~a"
                                   (config-object-name (car ancestor-provider))))
              acc]
             [(and ancestor-provider (entry-sealed? (cdr ancestor-provider)))
              (add-issue!
               (issue 'sealed-override field
                      (format "~a 覆盖被 ~a 以 sealed 拒绝"
                              (config-object-name node)
                              (config-object-name (car ancestor-provider)))
                      (hasheq 'at (entry-srcloc e))))
              acc]
             [(and (not ancestor-provider)
                   (not ancestor-default?)
                   (equal? perm '(override)))
              (add-issue!
               (issue 'dangling-override field
                      (format "~a 声明 override 但链内无提供者"
                              (config-object-name node))
                      (hasheq 'at (entry-srcloc e))))
              acc]
             [else
              (when ancestor-provider
                (add-origin! 'overridden (car ancestor-provider)
                             (cdr ancestor-provider) #f))
              (cons ne acc)])])))

    ;; Drop providers superseded by a descendant provider.
    (define maximal
      (for/list ([ne (in-list providers)]
                 #:unless (for/or ([other (in-list providers)])
                            (ancestor-of? (car ne) (car other))))
        ne))

    ;; Independence: maximal providers are pairwise incomparable.
    (define final-value
      (cond
        [(null? maximal) #f]
        [(null? (cdr maximal))
         (define ne (car maximal))
         (add-origin! 'provided (car ne) (cdr ne) #f)
         (entry-value (cdr ne))]
        [(not multi?)
         (add-issue!
          (issue 'multiple-introducers field
                 (format "独立引入者不唯一: ~a"
                         (map (compose config-object-name car) maximal))
                 (hasheq 'count (length maximal))))
         #f]
        [else
         ;; multi-introducer: values must unify (equal).
         (define vs (map (lambda (ne) (present-v (entry-value (cdr ne)))) maximal))
         (cond
           [(for/and ([v (in-list (cdr vs))]) (equal? v (car vs)))
            (for ([ne (in-list maximal)])
              (add-origin! 'provided (car ne) (cdr ne) #f))
            (entry-value (cdr (car maximal)))]
           [else
            (add-issue!
             (issue 'unification-conflict field
                    (format "并列具体值冲突: ~a" vs)
                    (hasheq 'values vs)))
            #f])]))

    ;; Defaults: most-derived unmasked default; incomparable differing
    ;; defaults are a conflict.
    (define default-entries
      (for/list ([ne (in-list touching)]
                 #:when (entry-default (cdr ne)))
        ne))
    (define maximal-defaults
      (for/list ([ne (in-list default-entries)]
                 #:unless (for/or ([other (in-list default-entries)])
                            (ancestor-of? (car ne) (car other))))
        ne))
    (define chosen-default
      (cond
        [(null? maximal-defaults) #f]
        [(null? (cdr maximal-defaults)) (car maximal-defaults)]
        [else
         (define dvs (map (lambda (ne) (present-v (entry-default (cdr ne))))
                          maximal-defaults))
         (cond
           [(for/and ([v (in-list (cdr dvs))]) (equal? v (car dvs)))
            (car maximal-defaults)]
           [else
            (add-issue!
             (issue 'default-conflict field
                    (format "并列默认值冲突: ~a" dvs)
                    (hasheq)))
            #f])]))

    (cond
      [final-value
       (hash-set! values-out field final-value)
       (set-add! explicit-set field)
       (when chosen-default
         (add-origin! 'default-yielded (car chosen-default)
                      (cdr chosen-default) #f))]
      [chosen-default
       (define dv (present-v (entry-default (cdr chosen-default))))
       (cond
         [(procedure? dv)
          ;; Computed default: deferred to the computed phase.
          (hash-set! unfilled-out field 'computed-pending)
          (add-origin! 'computed-default-pending (car chosen-default)
                       (cdr chosen-default) #f)]
         [else
          (hash-set! values-out field (present dv))
          (add-origin! 'defaulted (car chosen-default)
                       (cdr chosen-default) #f)])]
      [else
       (hash-set! unfilled-out field (if required? 'required 'no-provider))
       (when (and required? eager?)
         (add-issue!
          (issue 'eager-required-missing field
                 "eager 必填字段在求解期无定义" (hasheq))))])

    (hash-set! origins-out field (reverse origins)))

  ;; Stage gating: a stage runs to completion (warnings and errors both
  ;; accumulate within it); once a stage has produced errors, later stages do
  ;; not run.  Warnings collected so far are all retained.

  ;; Phase ①: immediate validators, on fields that ended with a value.
  ;; (Failure attribution mirrors the posterior phases; see with-context below.)
  (define (attributed-issue! field vd)
    (lambda (i)
      (define d0 (issue-data i))
      (define d1 (if (vdecl-srcloc vd)
                     (hash-set d0 'validator-at (vdecl-srcloc vd))
                     d0))
      (define o (for/last ([o (in-list (hash-ref origins-out field '()))]
                           #:when (memq (origin-kind o)
                                        '(provided defaulted computed)))
                  o))
      (define d2 (if o
                     (hash-set* d1
                                'value-from (origin-config-name o)
                                'value-at (origin-srcloc o))
                     d1))
      (struct-copy issue i [data d2])))
  (when (stage-clean?)
    (for ([fv (in-list (reverse immediate-validators))])
      (define field (car fv))
      (define vd (cadr fv))
      (define v (hash-ref values-out field #f))
      (when v
        (define enrich (attributed-issue! field vd))
        (apply-verdict! (call-validator (vdecl-proc vd) (present-v v))
                        field 'immediate (vdecl-srcloc vd)
                        (compose add-issue! enrich)
                        (compose add-warning! enrich)
                        add-skip!))))

  ;; Phase ②: computed defaults, lazily with cycle detection.
  (define computing (make-hasheq))
  (define view
    (make-resolved-view (lambda () values-out) env-set explicit-set))
  (define (force-field! field)
    (when (eq? (hash-ref unfilled-out field #f) 'computed-pending)
      (when (hash-ref computing field #f)
        (add-issue! (issue 'computed-cycle field "计算默认值循环依赖" (hasheq)))
        (hash-set! unfilled-out field 'no-provider))
      (unless (hash-ref computing field #f)
        (hash-set! computing field #t)
        (define os (hash-ref origins-out field '()))
        (define pending
          (for/first ([o (in-list os)]
                      #:when (eq? (origin-kind o) 'computed-default-pending))
            o))
        (define proc
          (for*/first ([n (in-list nodes)]
                       #:when (eq? (config-object-name n)
                                   (origin-config-name pending))
                       [e (in-value (merged-entry n field))]
                       #:when (and e (entry-default e)))
            (present-v (entry-default e))))
        (with-handlers ([exn:fail?
                         (lambda (ex)
                           (add-issue! (issue 'computed-default-failed field
                                              (exn-message ex) (hasheq)))
                           (hash-set! unfilled-out field 'no-provider))])
          (define v (proc view))
          (hash-set! values-out field (present v))
          (hash-remove! unfilled-out field)
          (hash-set! origins-out field
                     (append os (list (origin 'computed
                                              (origin-config-name pending)
                                              (origin-srcloc pending)
                                              #f))))))))
  (set-box! (resolved-view-force-box view) force-field!)
  (cond
    [(stage-clean?)
     (for ([field (in-list fields)]) (force-field! field))]
    [else
     ;; Gated: computed defaults never ran; normalize their pending markers.
     (for ([(field reason) (in-hash unfilled-out)]
           #:when (eq? reason 'computed-pending))
       (hash-set! unfilled-out field 'computed-skipped))])

  ;; Phase ③/④: posterior validators (field, then global).
  ;; Failure attribution: issues and warnings from a validator carry the
  ;; validator's declaration site and the provenance of the value it judged.
  (define ((with-context field vd sink) i)
    (sink (if field ((attributed-issue! field vd) i)
              ((attributed-issue!/no-field vd) i))))
  (define ((attributed-issue!/no-field vd) i)
    (if (vdecl-srcloc vd)
        (struct-copy issue i
                     [data (hash-set (issue-data i)
                                     'validator-at (vdecl-srcloc vd))])
        i))

  (define result
    (resolved values-out origins-out unfilled-out env-set
              '() '() '() explicit-set))
  (define (run-post! field vd)
    (apply-verdict! (call-validator (vdecl-proc vd) result)
                    field 'post (vdecl-srcloc vd)
                    (with-context (and (not (eq? field '%config)) field) vd add-issue!)
                    (with-context (and (not (eq? field '%config)) field) vd add-warning!)
                    add-skip!))
  (when (stage-clean?)
    (for ([fv (in-list (reverse post-validators))])
      (run-post! (car fv) (cadr fv))))
  (when (stage-clean?)
    (for* ([n (in-list nodes)]
           [gv (in-list (config-object-global-validators n))])
      (run-post! '%config gv)))

  (struct-copy resolved result
               [issues (reverse issues)]
               [warnings (reverse warnings)]
               [skipped (reverse skipped)]))

;; A mutable view used during the computed-default phase: reads of a
;; computed-pending field force it first (demand-driven dependency order).
(struct resolved-view (values-thunk env explicit force-box)
  #:methods gen:config-source
  [(define (config-source-suite v)
     (define p (hash-ref ((resolved-view-values-thunk v)) 'suite #f))
     (if p (present-v p) 'unknown))
   (define (config-source-ref v key [fail-result source-missing])
     (define forcer (unbox (resolved-view-force-box v)))
     (when forcer (forcer key))
     (define p (hash-ref ((resolved-view-values-thunk v)) key #f))
     (cond [p (present-v p)]
           [(procedure? fail-result) (fail-result)]
           [else fail-result]))
   (define (config-source-explicit? v key)
     (set-member? (resolved-view-explicit v) key))
   (define (config-source-keys v)
     (hash-keys ((resolved-view-values-thunk v))))])

(define (make-resolved-view values-thunk env explicit)
  (resolved-view values-thunk env explicit (box #f)))

