#lang racket

;; Validator combinators: common checks with rich verdicts built in
;; (docs/config-examples.md §1.4).  Each combinator returns a validator
;; procedure; immediate ones take the field value, posterior ones take the
;; resolved view.  The loader injects all of these into the .config sandbox,
;; so enum/range/filled checks need no hand-written lambda in config files.

(require "config.rkt"
         "source.rkt")

(provide one-of
         number-between
         integer-between
         nonempty-string
         string-matching
         list-where
         all-of
         require-filled
         warn-unfilled
         require-known
         warn-unknown)

;; ---------------------------------------------------------------------------
;; Immediate combinators (value -> verdict)

;; Small edit distance for "did you mean" hints.
(define (levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (define row (build-vector (add1 lb) values))
  (for ([i (in-range 1 (add1 la))])
    (define prev (vector-ref row 0))
    (vector-set! row 0 i)
    (for ([j (in-range 1 (add1 lb))])
      (define cur (vector-ref row j))
      (vector-set! row j
                   (min (add1 (vector-ref row (sub1 j)))
                        (add1 cur)
                        (+ prev (if (char=? (string-ref a (sub1 i))
                                            (string-ref b (sub1 j)))
                                    0 1))))
      (set! prev cur)))
  (vector-ref row lb))

(define (enum-hint v choices)
  (define (text x) (format "~a" x))
  (define vt (string-downcase (text v)))
  ;; Same text, different type (symbol vs string is the classic slip).
  (define type-twin
    (for/first ([c (in-list choices)]
                #:when (and (not (equal? c v))
                            (string-ci=? (text c) (text v))))
      c))
  (cond
    [type-twin
     (format "类型不符：枚举中是 ~s，给的是 ~s" type-twin v)]
    [else
     (define best
       (for/fold ([best #f] [bd +inf.0] #:result best)
                 ([c (in-list choices)])
         (define d (levenshtein vt (string-downcase (text c))))
         (if (< d bd) (values c d) (values best bd))))
     (and best
          (<= (levenshtein vt (string-downcase (text best)))
              (max 2 (quotient (string-length (text best)) 3)))
          (format "是否想要 ~s？" best))]))

(define (one-of . choices)
  ;; Finite enumeration membership, with "did you mean" attribution.
  (lambda (v)
    (or (and (member v choices) #t)
        (fail #:reason "不在枚举集内"
              #:expected choices
              #:given v
              #:hint (enum-hint v choices)))))

(define (number-between lo hi)
  (lambda (v)
    (cond
      [(not (real? v))
       (fail #:reason "期望数值" #:expected (list lo '.. hi) #:given v)]
      [(and (<= lo v) (<= v hi)) #t]
      [else (fail #:reason "超出闭区间"
                  #:expected (list lo '.. hi) #:given v)])))

(define (integer-between lo hi)
  (define in-range (number-between lo hi))
  (lambda (v)
    (if (exact-integer? v)
        (in-range v)
        (fail #:reason "期望整数" #:expected (list lo '.. hi) #:given v))))

(define (nonempty-string v)
  (or (and (string? v) (not (string=? v "")))
      (fail #:reason "期望非空字符串" #:given v)))

(define (string-matching pattern)
  (define rx (if (regexp? pattern) pattern (regexp pattern)))
  (lambda (v)
    (cond
      [(not (string? v)) (fail #:reason "期望字符串" #:given v)]
      [(regexp-match? rx v) #t]
      [else (fail #:reason "不匹配模式"
                  #:expected (object-name rx) #:given v)])))

(define (list-where pred)
  ;; Every element satisfies pred (itself a validator or plain predicate).
  (lambda (v)
    (cond
      [(not (list? v)) (fail #:reason "期望列表" #:given v)]
      [else
       (for/fold ([acc '()] #:result (if (null? acc) #t (reverse acc)))
                 ([item (in-list v)] [i (in-naturals)])
         (define r (pred item))
         (if (or (eq? r #t) (void? r))
             acc
             (cons (fail #:reason (format "第 ~a 项未通过" i) #:given item)
                   acc)))])))

(define (all-of . validators)
  ;; Conjunction; verdicts of all sub-checks accumulate (list protocol).
  (lambda (v)
    (for/list ([check (in-list validators)])
      (check v))))

;; ---------------------------------------------------------------------------
;; Posterior combinators (resolved view -> verdict)
;;
;; "快速检查是否无初始化值": unfilled fields are invisible to immediate
;; validators (which only run on present values), so filled-ness checks are
;; posterior.  This lets a site template harden fields at resolve time
;; without marking them eager in the base.

(define missing (gensym 'validators-missing-))

(define (filled-verdicts cfg fields on-missing)
  (for/fold ([acc '()] #:result (if (null? acc) #t (reverse acc)))
            ([f (in-list fields)])
    (if (eq? (config-source-ref cfg f missing) missing)
        (cons (on-missing f) acc)
        acc)))

(define (require-filled . fields)
  (lambda (cfg)
    (filled-verdicts cfg fields
                     (lambda (f)
                       (fail #:reason "字段无初始化值"
                             #:given f
                             #:hint "在配置中为其提供值，或移除本检查")))))

(define (warn-unfilled . fields)
  (lambda (cfg)
    (filled-verdicts cfg fields
                     (lambda (f)
                       (warn #:reason (format "字段 ~a 无初始化值" f))))))

;; Family membership, the reverse direction of require-filled: not "is
;; everything I need there" but "is everything there something I support".
;; Sweeps the enumerable fields matching pattern; members outside the
;; supported roster are flagged one by one, with a did-you-mean hint
;; against the roster.
;;
;; renamed: retired members, old name → new name (symbol) or a removal note
;; (string). A retired member is not an "unsupported" warning but a named
;; failure with the way out: an old name can still be introduced by a bare
;; () row and then read by nobody, and silently having no effect is worse
;; than an error. Retired members are checked whatever the pattern.
(define (family-verdicts cfg pattern allowed on-unknown #:renamed [renamed '()])
  (define match? (field-matcher pattern))
  (define retired (if (hash? renamed) renamed (make-immutable-hasheq renamed)))
  (for/fold ([acc '()] #:result (if (null? acc) #t (reverse acc)))
            ([f (in-list (config-source-keys cfg))])
    (cond
      [(hash-ref retired f #f) => (lambda (to) (cons (retired-verdict f to) acc))]
      [(and (match? f) (not (memq f allowed))) (cons (on-unknown f) acc)]
      [else acc])))

(define (retired-verdict f to)
  (if (symbol? to)
      (fail #:reason (format "~a 已更名为 ~a" f to)
            #:given f
            #:hint (format "改写为 [~a ...]" to)
            #:field f)
      (fail #:reason (format "~a 已移除" f)
            #:given f
            #:hint (format "~a" to)
            #:field f)))

(define (require-known pattern #:renamed [renamed '()] . allowed)
  (lambda (cfg)
    (family-verdicts cfg pattern allowed #:renamed renamed
                     (lambda (f)
                       (fail #:reason "族内出现不支持的字段"
                             #:expected allowed
                             #:given f
                             #:hint (enum-hint f allowed))))))

(define (warn-unknown pattern #:renamed [renamed '()] . allowed)
  (lambda (cfg)
    (family-verdicts cfg pattern allowed #:renamed renamed
                     (lambda (f)
                       (define h (enum-hint f allowed))
                       (warn #:reason (format "族内字段 ~a 不受支持~a" f
                                              (if h (format "；~a" h) "")))))))
