#lang racket

;; Host probing (docs/render-flow.md).  resolve stays pure and merely
;; carries each field's declared prober; probe-fields is the one explicitly
;; impure step.  A field is probed iff it is unfilled AND has a declared
;; prober — there is no marker value: an explicit value always wins.
;; (removed) masks a VALUE, so it re-opens probing only when the field has no
;; default to fall back to; with a default in the chain the default wins and
;; the prober still does not run.
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

;; Query the probe record injected via (resolve _ #:probes pr), mirroring
;; config-env-ref.  Two callers, two policies for "no record in scope":
;; a posterior validator (resolved) sees every field as a miss and typically
;; answers with skip; a phase-① computation (resolved view) gets the
;; probes-unready signal instead, because a computed value must not silently
;; fall back to a placeholder — it stays unfilled until the record exists.
(define (config-probe-ref r field [fail-result source-missing])
  (define-values (pr record!)
    (cond
      [(resolved? r)
       (values (resolved-probes r)
               (lambda (f hit?) (resolved-record-probe-read! r f hit?)))]
      [(resolved-view? r)
       ;; 相位①的计算位（计算值 / 计算默认值）：无探测记录时依赖未就绪
       ;; ——抛信号让引擎把该字段留作未填（'awaiting-probes），不兜底、
       ;; 不记账。未就绪不是未命中；两段式复解（纯求解 → 实探 → 带记录
       ;; 复解）里同一表达式再算一次即得值。
       (unless (probe-record? (resolved-view-probes r))
         (raise (probes-unready field)))
       (values (resolved-view-probes r)
               (lambda (f hit?) (resolved-view-record-probe-read! r f hit?)))]
      [else
       (raise-argument-error 'config-probe-ref
                             "resolved or resolved view" r)]))
  (define hit?
    (and (probe-record? pr)
         (hash-has-key? (probe-record-entries pr) field)))
  ;; 查询本身是被感知的数据：谁查过、命中与否，入查询名单（报告
  ;; 'probe-reads/'probe-misses）——沙箱代码的查询同样被看见。
  (record! field hit?)
  (if hit?
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
