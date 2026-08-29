#lang racket

;; Host probing (docs/render-flow.md).  resolve stays pure and merely
;; carries each field's declared prober; probe-fields is the one explicitly
;; impure step.  A field is probed iff it is unfilled AND has a declared
;; prober — there is no marker value: an explicit value always wins, and
;; masking a value with (removed) re-opens the field to probing.
;;
;; The probe record is a first-class value: probe-fields produces it,
;; make-probes hand-builds a fake one for injection, probes-set updates one
;; functionally (half-real records), render/consumers take it as input, and
;; reports archive it with timestamps.

(require racket/generic
         "source.rkt"
         "config.rkt")

(provide (struct-out probe-entry)
         (struct-out probe-failure)
         probe-record?
         probe-record-entries
         probe-record-fields
         probe-record-failures
         probe-fields
         make-probes
         probes-set
         probe-ref
         config-probe-ref
         with-probes)

;; entries: hasheq field -> probe-entry;  failures: (listof probe-failure)
(struct probe-entry (value at prober) #:transparent)
(struct probe-failure (field reason at prober) #:transparent)
(struct probe-record (entries failures) #:transparent)

(define (probe-record-fields pr)
  (sort (hash-keys (probe-record-entries pr)) symbol<?))

(define (prober-id proc)
  (or (object-name proc) 'anonymous))

;; Mirrors call-validator's fence: each prober runs under a fresh custodian,
;; shut down on the way out.
(define (call-prober proc r)
  (define cust (make-custodian))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian cust])
        (if (procedure-arity-includes? proc 1) (proc r) (proc))))
    (lambda () (custodian-shutdown-all cust))))

;; Run the prober of every unfilled field that has one.  A prober that
;; raises becomes a probe-failure entry — probing failure is data, never an
;; interrupt.  Arity-1 probers receive the resolved (to read sibling
;; fields); arity-0 probers take no arguments.
(define (probe-fields r)
  (define probers (resolved-probers r))
  (for/fold ([entries (hasheq)] [failures '()]
             #:result (probe-record entries (reverse failures)))
            ([field (in-list (sort (hash-keys (unfilled-fields r)) symbol<?))])
    (define proc (hash-ref probers field #f))
    (cond
      [(not proc) (values entries failures)]
      [else
       (define id (prober-id proc))
       (define at (current-seconds))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (values entries
                                  (cons (probe-failure field (exn-message e)
                                                       at id)
                                        failures)))])
         (define v (call-prober proc r))
         (values (hash-set entries field (probe-entry v at id)) failures))])))

;; Hand-built record for injection (fake probes in tests, dry runs).
;; Accepts a hash or an association list of (field . value).
(define (make-probes m #:prober [prober 'injected] #:at [at 0])
  (define h (if (hash? m) m (make-immutable-hash m)))
  (probe-record
   (for/hasheq ([(k v) (in-hash h)])
     (values k (probe-entry v at prober)))
   '()))

;; Functional update: half-real records = probe-fields, then override.
(define (probes-set pr field value #:prober [prober 'injected] #:at [at 0])
  (struct-copy probe-record pr
               [entries (hash-set (probe-record-entries pr) field
                                  (probe-entry value at prober))]))

;; Same fail contract as config-source-ref: a value is returned as-is, a
;; procedure is called, the default is the source-missing sentinel.
(define (probe-ref pr field [fail-result source-missing])
  (define e (hash-ref (probe-record-entries pr) field #f))
  (cond [e (probe-entry-value e)]
        [(procedure? fail-result) (fail-result)]
        [else fail-result]))

;; Posterior validators as environment evaluators (docs/render-flow.md §Ⅱ):
;; query the probe record injected via (resolve _ #:probes pr), mirroring
;; config-env-ref.  Meaningful only on a resolved — computed defaults (the
;; pure half of the pipeline) cannot see probes.  With no record injected,
;; every field is missing; a validator typically answers that with skip.
(define (config-probe-ref r field [fail-result source-missing])
  (unless (resolved? r)
    (raise-argument-error 'config-probe-ref
                          "resolved (posterior phases only)" r))
  (define pr (resolved-probes r))
  (if (probe-record? pr)
      (probe-ref pr field fail-result)
      (cond [(procedure? fail-result) (fail-result)]
            [else fail-result])))

;; Wrap any config-source so probed values flow through the ordinary ref
;; path: a filled field answers untouched, an unfilled field with a probed
;; value answers with it, anything else follows the caller's fail contract.
;; Keys gain the probed fields, so wildcard sweeps see them.  Stack a
;; recording source OUTSIDE this wrapper: the read set then reflects what
;; the consumer read, with values supplied by probing.
(struct probed-source (inner pr)
  #:methods gen:config-source
  [(define/generic ref config-source-ref)
   (define/generic suite-of config-source-suite)
   (define/generic explicit? config-source-explicit?)
   (define/generic keys-of config-source-keys)
   (define (config-source-suite s) (suite-of (probed-source-inner s)))
   (define (config-source-ref s key [fail-result source-missing])
     (define v (ref (probed-source-inner s) key source-missing))
     (if (eq? v source-missing)
         (probe-ref (probed-source-pr s) key fail-result)
         v))
   (define (config-source-explicit? s key)
     (explicit? (probed-source-inner s) key))
   (define (config-source-keys s)
     (remove-duplicates
      (append (keys-of (probed-source-inner s))
              (hash-keys (probe-record-entries (probed-source-pr s))))))])

(define (with-probes src pr)
  (probed-source src pr))
