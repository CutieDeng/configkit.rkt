#lang racket

;; Read recording and .rktd reports (docs/render-flow.md §2, §Ⅴ).
;;
;; A recording source wraps any config-source; every ref enters the read set,
;; reads of unfilled fields are counted, and the consumer may attach notes.
;; The canonical diagnostic artifact is a single read-able datum (.rktd);
;; human-facing tables are derived views of the same data.

(require racket/generic
         racket/set
         "source.rkt"
         "config.rkt")

(provide explain-resolved
         explain-issue
         make-recording-source
         record?
         record-reads
         record-unfilled
         record-notes
         record-note!
         unread-fields/record
         make-report
         write-report
         report-format-version)

(define report-format-version 1)

;; ---------------------------------------------------------------------------
;; Recording source

(struct record (reads-box unfilled-box notes-box) #:transparent)

(struct recording-source (inner rec)
  #:methods gen:config-source
  [(define/generic ref config-source-ref)
   (define/generic suite-of config-source-suite)
   (define/generic explicit? config-source-explicit?)
   (define/generic keys-of config-source-keys)
   (define (config-source-suite s)
     (suite-of (recording-source-inner s)))
   (define (config-source-ref s key [fail-result source-missing])
     (define rec (recording-source-rec s))
     (define reads (record-reads-box rec))
     (unless (assq key (unbox reads))
       (set-box! reads (cons (cons key (length (unbox reads))) (unbox reads))))
     (define v (ref (recording-source-inner s) key source-missing))
     (cond
       [(eq? v source-missing)
        (define u (record-unfilled-box rec))
        (set-box! u (hash-update (unbox u) key add1 0))
        (cond [(procedure? fail-result) (fail-result)]
              [else fail-result])]
       [else v]))
   (define (config-source-explicit? s key)
     (explicit? (recording-source-inner s) key))
   (define (config-source-keys s)
     (keys-of (recording-source-inner s)))])

(define (make-recording-source source)
  (define rec (record (box '()) (box (hasheq)) (box '())))
  (values (recording-source source rec) rec))

(define (record-reads rec)
  ;; Fields in first-read order.
  (map car (sort (unbox (record-reads-box rec)) < #:key cdr)))

(define (record-unfilled rec) (unbox (record-unfilled-box rec)))

(define (record-note! rec field message)
  (set-box! (record-notes-box rec)
            (cons (list field message) (unbox (record-notes-box rec)))))

(define (record-notes rec) (reverse (unbox (record-notes-box rec))))

(define (unread-fields/record source rec)
  ;; Filled-but-never-read: the typo detector (docs §3.1 consequence 2).
  (define read-set (list->seteq (record-reads rec)))
  (sort (for/list ([k (in-list (config-source-keys source))]
                   #:unless (set-member? read-set k))
          k)
        symbol<?))

;; ---------------------------------------------------------------------------
;; Reports: one read-able datum, no closures, no opaque structs

(define (sanitize v)
  (cond
    [(procedure? v) '<procedure>]
    [(path? v) (path->string v)]
    [(hash? v) (for/hash ([(k x) (in-hash v)]) (values (sanitize k) (sanitize x)))]
    [(list? v) (map sanitize v)]
    [(pair? v) (cons (sanitize (car v)) (sanitize (cdr v)))]
    [(vector? v) (map sanitize (vector->list v))]
    [(or (number? v) (string? v) (symbol? v) (boolean? v) (null? v) (void? v)) v]
    [(issue? v) (sanitize-issue v)]
    [(origin? v) (sanitize-origin v)]
    [else (format "~a" v)]))

(define (sanitize-issue i)
  (hash 'kind (issue-kind i)
        'field (issue-field i)
        'message (issue-message i)
        'data (sanitize (issue-data i))))

(define (sanitize-origin o)
  (hash 'kind (origin-kind o)
        'config (origin-config-name o)
        'at (sanitize (origin-srcloc o))
        'info (sanitize (origin-info o))))

(define (make-report #:function function
                     #:resolved [r #f]
                     #:record [rec #f]
                     #:source [source #f])
  (define base
    (hash 'format-version report-format-version
          'kind (if rec 'consumer-report 'resolve-report)
          'function function))
  (define with-resolved
    (if r
        ;; values carries FILLED fields only; unfilled ones live under the
        ;; 'unfilled key — no placeholder symbol that a real value could
        ;; collide with.
        (let* ([absent (gensym)]
               [values-view
                (for*/hash ([k (in-list (config-source-keys r))]
                            [v (in-value (config-source-ref r k absent))]
                            #:unless (eq? v absent))
                  (values k (sanitize v)))])
          (hash-set* base
                     'verdict (if (resolved-ok? r) 'ok 'failed)
                     'id (sanitize (resolved-id r))
                     'class (sanitize (resolved-class r))
                     'suite (config-source-suite r)
                     'values values-view
                     'issues (map sanitize-issue (resolved-issues r))
                     'warnings (map sanitize-issue (resolved-warnings r))
                     'unfilled (sanitize (unfilled-fields r))
                     'skipped (sanitize (resolved-skipped r))
                     'inoperative (sanitize (inoperative-declarations r))
                     'provenance
                     (for/hash ([k (in-list (config-source-keys r))]
                                #:when (pair? (provenance-ref r k)))
                       (values k (map sanitize-origin (provenance-ref r k))))))
        base))
  (if rec
      (hash-set* with-resolved
                 'read-set (record-reads rec)
                 'unfilled-reads (sanitize (record-unfilled rec))
                 'notes (sanitize (record-notes rec))
                 'unread-fields
                 (if source (unread-fields/record source rec) '()))
      with-resolved))

;; ---------------------------------------------------------------------------
;; Human-facing expansion: the derived view of the same data

(define (explain-issue i)
  (define d (issue-data i))
  (define (line key label)
    (define v (hash-ref d key #f))
    (if v (format "    ~a~a\n" label
                  (if (string? v) v (format "~s" v))) ""))
  (string-append
   (format "  ✗ ~a: ~a\n" (issue-field i) (issue-message i))
   (line 'given      "给定:     ")
   (line 'expected   "期望:     ")
   (line 'hint       "提示:     ")
   (if (and (hash-ref d 'value-from #f) (hash-ref d 'value-at #f))
       (format "    值来自:   ~a @ ~a\n"
               (hash-ref d 'value-from) (hash-ref d 'value-at))
       "")
   (line 'validator-at "验证器于: ")))

(define (explain-resolved r)
  (define out (open-output-string))
  (define issues (resolved-issues r))
  (define warnings (resolved-warnings r))
  (unless (null? issues)
    (fprintf out "错误 (~a):\n" (length issues))
    (for ([i (in-list issues)]) (display (explain-issue i) out)))
  (unless (null? warnings)
    (fprintf out "警告 (~a):\n" (length warnings))
    (for ([i (in-list warnings)]) (display (explain-issue i) out)))
  (unless (null? (resolved-skipped r))
    (fprintf out "跳过的验证器 (~a):\n" (length (resolved-skipped r)))
    (for ([s (in-list (resolved-skipped r))])
      (fprintf out "  ~a @ ~a：~a\n" (car s) (caddr s) (cadddr s))))
  (define unfilled (unfilled-fields r))
  (unless (hash-empty? unfilled)
    (fprintf out "未填字段 (~a):\n" (hash-count unfilled))
    (for ([(f why) (in-hash unfilled)])
      (fprintf out "  ~a（~a）\n" f why)))
  (define text (get-output-string out))
  (if (string=? text "") "无异常\n" text))

(define (write-report report path)
  (call-with-output-file path
    (lambda (out) (write report out) (newline out))
    #:exists 'truncate/replace)
  path)
