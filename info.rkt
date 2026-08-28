#lang info

;; configkit: composable configuration framework — partial-record configs,
;; unification-based resolve with provenance, a consumer-facing source
;; protocol, read recording, and .rktd diagnostic reports.
;; Working name; renaming touches this file and the directory only.

(define collection "configkit")
(define deps '("base" "sandbox-lib"))
(define build-deps '("rackunit-lib" "scribble-lib" "racket-doc"))
(define scribblings '(("scribblings/configkit.scrbl" ())))
(define pkg-desc "Composable configuration framework (configs, unification, provenance)")
(define version "0.1")
(define license 'MIT)
