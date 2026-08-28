#lang racket

(require (except-in rackunit fail)
         "../config.rkt"
         "../source.rkt")

(define (issue-kinds r) (map issue-kind (resolved-issues r)))
(define (has-issue? r kind [field #f])
  (for/or ([i (in-list (resolved-issues r))])
    (and (eq? (issue-kind i) kind)
         (or (not field) (eq? (issue-field i) field)))))

;; ---------------------------------------------------------------------------
;; Chains: defaults yield, overrides, provenance

(define-config base
  [copies    ((default 2) (validate exact-positive-integer?))]
  [tune      ((default "base"))]
  [dryrun    () false]                       ; boolean literal normalization
  [spec-src  (introduce required eager)]
  [hw-avail  (introduce required)])          ; noneager

(define-config site
  #:extends base
  [output-parent (sealed) "/srv/spec/runs"]
  [copies        () 2])

(define-config job
  #:extends site
  [spec-src () "/opt/cpu2026"]
  [hw-avail () "Jun-2026"]
  [copies   (override) 4]
  [tune     () "peak"])                      ; default yields, no conflict

(define r1 (resolve job))
(check-true (resolved-ok? r1) (format "~a" (resolved-issues r1)))
(check-equal? (resolved-value r1 'copies) 4)
(check-equal? (resolved-value r1 'tune) "peak")
(check-equal? (resolved-value r1 'output-parent) "/srv/spec/runs")
;; Explicit false is a value, not absence.
(check-false (resolved-value r1 'dryrun 'absent))
;; Provenance: site's value overridden, job provided, default yielded.
(define copies-origins (map origin-kind (provenance-ref r1 'copies)))
(check-not-false (memq 'provided copies-origins))
(check-not-false (memq 'overridden copies-origins))
(check-not-false (memq 'default-yielded (map origin-kind (provenance-ref r1 'tune))))

;; resolved implements the source protocol.
(check-true (config-source? r1))
(check-true (config-source-explicit? r1 'copies))
(check-false (config-source-explicit? r1 'output-format))
(check-eq? (config-source-ref r1 'no-such 'absent) 'absent)

;; ---------------------------------------------------------------------------
;; eager vs noneager required

(define r-base (resolve base))
(check-true (has-issue? r-base 'eager-required-missing 'spec-src))
(check-eq? (hash-ref (unfilled-fields r-base) 'hw-avail) 'required)
(check-false (has-issue? r-base 'eager-required-missing 'hw-avail))

;; ---------------------------------------------------------------------------
;; Chain re-introduction is inoperative (recorded, no issue, value not applied)

(define-config reintro-job
  #:extends site
  [spec-src () "/opt/x"]
  [hw-avail () "x"]
  [copies (introduce) 9])                    ; site already provides a value

(define r2 (resolve reintro-job))
(check-equal? (resolved-value r2 'copies) 2)  ; site's value stands
(check-false (has-issue? r2 'multiple-introducers))
(define inop (inoperative-declarations r2))
(check-equal? (length inop) 1)
(check-eq? (car (car inop)) 'copies)

;; ---------------------------------------------------------------------------
;; sealed refuses override; dangling override

(define-config sealed-breaker
  #:extends site
  [spec-src () "/opt/x"]
  [hw-avail () "x"]
  [output-parent (override) "/tmp/evil"])

(define r3 (resolve sealed-breaker))
(check-true (has-issue? r3 'sealed-override 'output-parent))
(check-equal? (resolved-value r3 'output-parent) "/srv/spec/runs")

(define-config dangler
  [ghost (override) 5])
(define r4 (resolve dangler))
(check-true (has-issue? r4 'dangling-override 'ghost))
(check-eq? (resolved-value r4 'ghost 'absent) 'absent)

;; ---------------------------------------------------------------------------
;; removed: masks ancestor values, falls back to the root default

(define-config remover
  #:extends site
  [spec-src () "/opt/x"]
  [hw-avail () "x"]
  [copies (removed)])

(define r5 (resolve remover))
(check-equal? (resolved-value r5 'copies) 2)  ; base default survives removal
(check-not-false (memq 'removed (map origin-kind (provenance-ref r5 'copies))))
(check-not-false (memq 'masked-by-removal
                       (map origin-kind (provenance-ref r5 'copies))))

;; ---------------------------------------------------------------------------
;; Parallel composition: singlenew default; multi-introducer opt-in

(define-config tool-a [compiler-dir (introduce) "/opt/gcc-15"])
(define-config tool-b [compiler-dir (introduce) "/opt/gcc-15"])
(define r6 (resolve (config tool-a tool-b)))
(check-true (has-issue? r6 'multiple-introducers 'compiler-dir))

(define-config tool-c [compiler-dir (introduce multi-introducer) "/opt/gcc-15"])
(define r7 (resolve (config tool-a tool-c)))
(check-true (resolved-ok? r7) (format "~a" (resolved-issues r7)))
(check-equal? (resolved-value r7 'compiler-dir) "/opt/gcc-15")

(define-config tool-d [compiler-dir (introduce multi-introducer) "/usr"])
(define r8 (resolve (config tool-a tool-d)))
(check-true (has-issue? r8 'unification-conflict 'compiler-dir))

;; Diamond: shared ancestor, one branch overrides — no false independence.
(define-config job-b #:extends site [spec-src () "/opt/x"] [hw-avail () "x"])
(define r9 (resolve (config job job-b)))
(check-equal? (resolved-value r9 'copies) 4)
(check-false (has-issue? r9 'multiple-introducers 'copies))

;; ---------------------------------------------------------------------------
;; Hash coercion: permissive entries, parallel conflict surfaces

(define r10 (resolve (config job (hash 'copies 8))))
(check-true (has-issue? r10 'unification-conflict 'copies))
(define r11 (resolve (config job (hash 'iterations 3))))
(check-equal? (resolved-value r11 'iterations) 3)

;; ---------------------------------------------------------------------------
;; Validators: append along the chain, rich verdicts

(define-config strict-site
  #:extends base
  [spec-src () "/opt/x"]
  [hw-avail () "x"]
  [copies ((validate (lambda (n) (or (<= n 64)
                                     (fail #:reason "copies 超上限"
                                           #:given n #:hint "减小 copies")))))
           128])

(define r12 (resolve strict-site))
(check-true (has-issue? r12 'validator-failed 'copies))
(define fail-msg
  (for/first ([i (in-list (resolved-issues r12))]
              #:when (eq? (issue-kind i) 'validator-failed))
    (issue-message i)))
(check-equal? fail-msg "copies 超上限")

;; The base validator (exact-positive-integer?) still applies to overrides.
(define-config bad-type
  #:extends site
  [spec-src () "/opt/x"] [hw-avail () "x"]
  [copies (override) "four"])
(define r13 (resolve bad-type))
(check-true (has-issue? r13 'validator-failed 'copies))

;; skip from an immediate validator is itself an error.
(define-config bad-skip
  [x ((validate (lambda (v) (skip #:reason "nope")))) 1])
(check-true (has-issue? (resolve bad-skip) 'validator-failed 'x))

;; ---------------------------------------------------------------------------
;; Computed defaults: read other fields, demand order, cycles

(define-config computed
  [copies () 4]
  [build-ncpus ((default (lambda (v) (* 2 (config-source-ref v 'copies)))))]
  [threads ((default (lambda (v) (config-source-ref v 'build-ncpus))))])

(define r14 (resolve computed))
(check-true (resolved-ok? r14) (format "~a" (resolved-issues r14)))
(check-equal? (resolved-value r14 'build-ncpus) 8)
(check-equal? (resolved-value r14 'threads) 8)
(check-not-false (memq 'computed (map origin-kind (provenance-ref r14 'build-ncpus))))

(define-config cyclic
  [a ((default (lambda (v) (config-source-ref v 'b 0))))]
  [b ((default (lambda (v) (config-source-ref v 'a 0))))])
(check-true (has-issue? (resolve cyclic) 'computed-cycle))

;; ---------------------------------------------------------------------------
;; Posterior validators, validation environment, self-skip

(define-config guarded
  [relax (env (default false))]
  [copies ((validate/post
            (lambda (cfg)
              (if (config-env-ref cfg 'relax)
                  (skip #:reason "relax 已开启")
                  (or (<= (config-source-ref cfg 'copies) 64)
                      (fail #:reason "copies 超上限"))))))
          100])

(define r15 (resolve guarded))
(check-true (has-issue? r15 'validator-failed 'copies))
(check-true (null? (resolved-skipped r15)))

(define r16 (resolve (config guarded (hash 'relax 'true))))
(check-false (has-issue? r16 'validator-failed 'copies))
(check-equal? (length (resolved-skipped r16)) 1)
(check-equal? (list-ref (car (resolved-skipped r16)) 3) "relax 已开启")

;; config-env-ref rejects fields not exported to the environment.
(check-exn exn:fail? (lambda () (config-env-ref r15 'copies)))

;; ---------------------------------------------------------------------------
;; Global posterior validators

(define-config globally-checked
  #:validate/post (lambda (cfg)
                    (or (equal? (config-source-ref cfg 'mode 'x) "safe")
                        (fail #:reason "mode 必须为 safe")))
  [mode () "fast"])
(check-true (has-issue? (resolve globally-checked) 'validator-failed '%config))

;; ---------------------------------------------------------------------------
;; Error accumulation within a stage; gating between stages

(define-config multi-bad
  [a (override) 1]                            ; dangling
  [b ((validate (lambda (v) "b 不合法"))) 2]  ; validator fail
  [c (introduce required eager)])             ; eager missing
(define r17 (resolve multi-bad))
;; 合并期内错误累积（同阶段一次报全）……
(check-true (has-issue? r17 'dangling-override 'a))
(check-true (has-issue? r17 'eager-required-missing 'c))
(check-equal? (length (resolved-issues r17)) 2)
;; ……但阶段门控：合并期已有错误，① 不再运行，b 的验证器错误不出现
(check-false (has-issue? r17 'validator-failed 'b))

;; Same config giving a field two values is a construction error;
;; multiple rows merging properties (value + validator rows) are fine.
(check-exn exn:fail?
           (lambda ()
             (let ()
               (define-config dup [x () 1] [x () 2])
               dup)))
(let ()
  (define-config split-rows
    [x () 1]
    [x ((validate exact-positive-integer?))])
  (check-true (resolved-ok? (resolve split-rows)))
  (check-equal? (resolved-value (resolve split-rows) 'x) 1))

;; ---------------------------------------------------------------------------
;; Warnings vs errors: separate ledgers, stage gating

;; Warnings never block, collect across stages.
(define-config warny
  [a ((validate (lambda (v) (warn #:reason "a 有点可疑")))) 1]
  [a ((validate/post (lambda (cfg) (warn #:reason "a 后验提醒"))))])
(define rw (resolve warny))
(check-true (resolved-ok? rw) (format "~a" (resolved-issues rw)))
(check-equal? (map issue-message (resolved-warnings rw))
              '("a 有点可疑" "a 后验提醒"))

;; A merge-stage error gates phase ①: effectful validators never run.
(define ran-immediate (box #f))
(define-config gate-a [k (introduce) 1])
(define-config gate-b
  [k (introduce) 2]
  [other ((validate (lambda (v) (set-box! ran-immediate #t) #t))) 5])
(define rg (resolve (config gate-a gate-b)))
(check-true (has-issue? rg 'multiple-introducers 'k))
(check-false (unbox ran-immediate) "合并期已有错误，①不应执行")

;; A phase-① error gates ③/④, but ①'s own warnings are fully collected.
(define ran-post (box #f))
(define-config gated
  [x ((validate (lambda (v) (warn #:reason "x 警告")))) 1]
  [y ((validate (lambda (v) "y 错误"))) 2]
  [z ((validate/post (lambda (cfg) (set-box! ran-post #t) #t))) 3])
(define rg2 (resolve gated))
(check-false (resolved-ok? rg2))
(check-equal? (map issue-message (resolved-warnings rg2)) '("x 警告"))
(check-true (has-issue? rg2 'validator-failed 'y))
(check-false (unbox ran-post) "①出错后③不应执行")

;; Gated computed defaults surface as computed-skipped, not silent absence.
(define-config gated-computed
  [p (introduce) 1]
  [q ((default (lambda (v) 9)))])
(define-config gated-computed-b [p (introduce) 2])
(define rg3 (resolve (config gated-computed gated-computed-b)))
(check-eq? (hash-ref (unfilled-fields rg3) 'q) 'computed-skipped)
