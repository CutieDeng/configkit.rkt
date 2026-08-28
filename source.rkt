#lang racket

;; The consumer-facing configuration protocol.  Engines and renderers depend
;; only on this interface; each configuration representation supplies an
;; adapter.  Nothing in this library knows about any particular application.

(require racket/generic)

(provide gen:config-source
         config-source?
         config-source-suite
         config-source-ref
         config-source-explicit?
         config-source-keys
         config-source-ref-group
         field-matcher
         source-missing)

;; Distinguished "no value" result for ref.  A gensym cannot collide with any
;; configuration value; callers that pass no fail handler receive it.
(define source-missing (gensym 'config-source-missing-))

(define-generics config-source
  (config-source-suite config-source)
  (config-source-ref config-source key [fail])
  (config-source-explicit? config-source key)
  (config-source-keys config-source))

;; Wildcard consumption: read every field whose name matches pattern — a
;; symbol/string prefix (e.g. 'env: for env:OMP, env:AFFINITY, ...) or a
;; regexp — through the protocol.  Each member goes through a genuine ref,
;; so a recording source sees the sweep as real reads, unfilled members
;; included; the result carries the filled matches only.
(define (config-source-ref-group src pattern)
  (define match? (field-matcher pattern))
  (for/fold ([out (hasheq)])
            ([k (in-list (config-source-keys src))]
             #:when (match? k))
    (define v (config-source-ref src k source-missing))
    (if (eq? v source-missing) out (hash-set out k v))))

;; Family membership test shared by the wildcard operations: a symbol/string
;; pattern matches as a name prefix, a regexp matches the whole name.
(define (field-matcher pattern)
  (if (regexp? pattern)
      (lambda (k) (regexp-match? pattern (symbol->string k)))
      (let ([p (if (symbol? pattern) (symbol->string pattern) pattern)])
        (lambda (k) (string-prefix? (symbol->string k) p)))))
