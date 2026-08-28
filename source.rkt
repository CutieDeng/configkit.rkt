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
         source-missing)

;; Distinguished "no value" result for ref.  A gensym cannot collide with any
;; configuration value; callers that pass no fail handler receive it.
(define source-missing (gensym 'config-source-missing-))

(define-generics config-source
  (config-source-suite config-source)
  (config-source-ref config-source key [fail])
  (config-source-explicit? config-source key)
  (config-source-keys config-source))
