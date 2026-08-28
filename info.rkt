#lang info

;; configkit: composable configuration framework — partial-record fragments,
;; unification-based resolve with provenance, a consumer-facing source
;; protocol, read recording, and .rktd diagnostic reports.
;; Working name; renaming touches this file and the directory only.

(define collection "configkit")
(define deps '("base"))
(define build-deps '("rackunit-lib"))
(define pkg-desc "Composable configuration framework (fragments, unification, provenance)")
(define version "0.1")
(define license 'MIT)
