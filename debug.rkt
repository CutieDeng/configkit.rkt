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

;; Consumer development loop: run a consumer (e.g. a renderer under
;; construction) against a recording view, print what it read, what it hit
;; unfilled, and what it never touched; return the consumer's result and the
;; .rktd-shaped report.
(define (debug-consume c proc
                       #:function [function 'debug-consume]
                       #:out [out (current-output-port)])
  (define r (->resolved c))
  (define-values (src rec) (make-recording-source r))
  (define result (proc src))
  (fprintf out "―― ~a\n读集: ~a\n" function (record-reads rec))
  (define u (record-unfilled rec))
  (unless (hash-empty? u)
    (fprintf out "未填读取: ~a\n" u))
  (define unread (unread-fields/record r rec))
  (unless (null? unread)
    (fprintf out "未读字段: ~a\n" unread))
  (values result
          (make-report #:function function #:resolved r
                       #:record rec #:source r)))

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
