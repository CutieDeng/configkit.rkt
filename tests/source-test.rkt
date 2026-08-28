#lang racket

;; Library self-test.  Deliberately implements the protocol with a toy
;; representation: proves the library carries no application dependency.

(require rackunit
         "../source.rkt")

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
