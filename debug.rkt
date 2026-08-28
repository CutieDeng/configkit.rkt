#lang racket

;; Application-facing development helpers: quick checks while building an
;; application on configkit — its config trees, its head table, and its
;; consumers (renderers etc.).  Everything here is a thin veneer over the
;; public query surfaces; nothing extra is recorded, nothing is production
;; path.  Safe to call from a REPL or a dev script.

(require "config.rkt"
         "source.rkt"
         "record.rkt"
         "loader.rkt")

(provide peek
         peek-field
         check-config
         resolve-summary
         debug-consume
         list-configs
         dump-report)

(define (->resolved c) (if (resolved? c) c (resolve c)))

;; One-line health summary of a config/composition.
(define (resolve-summary c)
  (define r (->resolved c))
  (hash 'id (resolved-id r)
        'class (resolved-class r)
        'ok? (resolved-ok? r)
        'errors (length (resolved-issues r))
        'warnings (length (resolved-warnings r))
        'skipped (length (resolved-skipped r))
        'unfilled (hash-count (unfilled-fields r))
        'fields (length (config-source-keys r))))

;; Resolve (if needed), print the human-facing expansion plus the value
;; table, return the resolved view for further poking.
(define (peek c #:out [out (current-output-port)])
  (define r (->resolved c))
  (fprintf out "―― peek ~a\n" (resolve-summary r))
  (display (explain-resolved r) out)
  (fprintf out "值:\n")
  (for ([k (in-list (sort (config-source-keys r) symbol<?))])
    (fprintf out "  ~a = ~s\n" k (config-source-ref r k '<unfilled>)))
  r)

;; One field: value plus its full definition chain.
(define (peek-field c field #:out [out (current-output-port)])
  (define r (->resolved c))
  (fprintf out "~a = ~s\n" field (config-source-ref r field '<unfilled>))
  (for ([o (in-list (provenance-ref r field))])
    (fprintf out "  ~a  ~a @ ~a~a\n"
             (origin-kind o) (origin-config-name o) (origin-srcloc o)
             (if (origin-info o) (format "  (~a)" (origin-info o)) "")))
  r)

;; Boolean gate for dev scripts: prints the expansion only when unhealthy.
(define (check-config c #:out [out (current-output-port)])
  (define r (->resolved c))
  (unless (resolved-ok? r)
    (display (explain-resolved r) out))
  (resolved-ok? r))

;; Consumer development loop: consume/record (the production loop) plus a
;; printout of what was read, hit unfilled, marked, flagged, and never
;; touched — everything printed straight from the report it returns.
(define (debug-consume c proc
                       #:function [function 'debug-consume]
                       #:out [out (current-output-port)])
  (define-values (result report)
    (consume/record c proc #:function function))
  (fprintf out "―― ~a\n读集: ~a\n" function (hash-ref report 'read-set))
  (define (show key label)
    (define v (hash-ref report key))
    (unless (null? v) (fprintf out "~a: ~a\n" label v)))
  (show 'unfilled-reads "未填读取")
  (show 'marks "标记")
  (show 'flags "消费问题")
  (show 'unread-fields "未读字段")
  (values result report))

;; Enumerate loadable references under the current (or given) head table —
;; the quick way to verify a head table points where the application thinks.
(define (list-configs #:heads [heads (current-config-search-heads)])
  (for/hash ([(head root) (in-hash heads)])
    (values head
            (if (directory-exists? root)
                (sort
                 (for/list ([p (in-directory root)]
                            #:when (and (file-exists? p)
                                        (regexp-match? #rx"\\.config$"
                                                       (path->string p))))
                   (string-append
                    "@" (symbol->string head) "/"
                    (regexp-replace
                     #rx"\\.config$"
                     (path->string (find-relative-path root p)) "")))
                 string<?)
                'missing-root))))

;; Resolve and drop a canonical .rktd report in one call.
(define (dump-report c path #:function [function 'dev-check])
  (write-report (make-report #:function function #:resolved (->resolved c))
                path))
