#lang racket

;; Library self-test.  Deliberately implements the protocol with a toy
;; representation: proves the library carries no application dependency.

(require rackunit
         "../source.rkt"
         "../record.rkt")

(struct toy (suite table)
  #:methods gen:config-source
  [(define (config-source-suite s) (toy-suite s))
   (define (config-source-ref s key [fail source-missing])
     (cond
       [(hash-has-key? (toy-table s) key) (hash-ref (toy-table s) key)]
       [(procedure? fail) (fail)]
       [else fail]))
   (define (config-source-explicit? s key)
     (hash-has-key? (toy-table s) key))
   (define (config-source-keys s)
     (hash-keys (toy-table s)))])

(define t (toy 'demo (hash 'a 1 'flag #f)))

(check-true (config-source? t))
(check-eq? (config-source-suite t) 'demo)
(check-equal? (config-source-ref t 'a) 1)
;; An explicit #f is a value, not absence.
(check-false (config-source-ref t 'flag 'absent))
(check-eq? (config-source-ref t 'missing 'absent) 'absent)
(check-eq? (config-source-ref t 'missing (lambda () 'thunked)) 'thunked)
(check-eq? (config-source-ref t 'missing) source-missing)
(check-true (config-source-explicit? t 'a))
(check-false (config-source-explicit? t 'missing))
(check-not-false (memq 'a (config-source-keys t)))

;; ---------------------------------------------------------------------------
;; 作用域回退（config-source-ref/fallback）：子选项模式的查找承载

(define tb (toy 'demo (hash 'coptimize ""
                            'bench:710:coptimize "-fno-strict-aliasing"
                            'bench:720:flag #f)))

;; 特异名命中即答；缺特异名回退到通用名
(check-equal? (config-source-ref/fallback tb '(bench:710:coptimize coptimize))
              "-fno-strict-aliasing")
(check-equal? (config-source-ref/fallback tb '(bench:711:coptimize coptimize))
              "")
;; 显式 #f 是值，参与命中
(check-false (config-source-ref/fallback tb '(bench:720:flag flag) 'absent))
;; 全链皆缺 → 普通 fail 契约三形态
(check-eq? (config-source-ref/fallback tb '(x y) 'absent) 'absent)
(check-equal? (config-source-ref/fallback tb '(x y) (lambda () 9)) 9)
(check-eq? (config-source-ref/fallback tb '(x y)) source-missing)

;; 录制语义：只记真正消费的名字；预期缺席的特异名不进未填读取名单
(define-values (rsrc rec) (make-recording-source tb))
(check-equal? (config-source-ref/fallback rsrc '(bench:711:coptimize coptimize))
              "")
(check-equal? (record-reads rec) '(coptimize))
(check-equal? (record-unfilled rec) '())
