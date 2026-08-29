#lang racket

;; Render driver (docs/render-flow.md §Ⅲ/Ⅳ).  The application's renderer
;; only reads through the protocol and emits text through a writer; this
;; module owns the failure path.
;;
;; checked mode, on the first unfilled read: capture a composable
;; continuation at the read point and abort to the engine prompt; the
;; handler deletes the half-written product, swaps the writer to a no-op,
;; flips the policy to "record and continue", then resumes the continuation
;; with a placeholder.  The renderer finishes the remaining template in the
;; same pass — the full read set and every missing field are collected
;; without redoing the prefix, and no partial product survives.
;;
;; Scoping note (experimentally verified): a parameter-based sink IS
;; workable — provided the binding sits outside the prompt and the swap is
;; expressed by wrapping the resume in a fresh parameterize.  A binding
;; inside the captured extent bounces back on resume.  This module uses
;; boxes instead, for three reasons: the invariant becomes structural
;; rather than positional (no refactor can move a binding into the
;; captured extent); the renderer writes through the explicit emit
;; argument, so nothing needs dynamic lookup; and after a failure the sink
;; must stay dead even for closures that escape the render's dynamic
;; extent — a parameterize around the resume only covers the resumed
;; extent.

(require racket/generic
         "source.rkt"
         "config.rkt"
         "probe.rkt"
         "record.rkt")

(provide render-writer?
         make-string-writer
         make-file-writer
         no-op-writer
         unfilled-placeholder
         unfilled-placeholder?
         unfilled-placeholder-field
         (struct-out render-result)
         call-renderer)

;; --- writers ---------------------------------------------------------------

;; emit : displayable -> void;  finish : -> product;  discard : -> void
;; (discard must leave no partial product behind).
(struct render-writer (emit finish discard))

(define (make-string-writer)
  (define out (open-output-string))
  (render-writer (lambda (s) (display s out))
                 (lambda () (get-output-string out))
                 void))

(define (make-file-writer path)
  (define out (open-output-file path #:exists 'truncate/replace))
  (render-writer (lambda (s) (display s out))
                 (lambda () (close-output-port out) path)
                 (lambda ()
                   (close-output-port out)
                   (when (file-exists? path) (delete-file path)))))

(define (no-op-writer)
  (render-writer void (lambda () #f) void))

;; --- unfilled placeholder --------------------------------------------------

;; What a lenient (or post-suspension) read of an unfilled field returns:
;; detectable by the application, and displays as <unfilled:field> when
;; formatted into text.
(struct unfilled-placeholder (field)
  #:transparent
  #:methods gen:custom-write
  [(define (write-proc p port mode)
     (fprintf port "<unfilled:~a>" (unfilled-placeholder-field p)))])

;; --- the policy source -----------------------------------------------------

(define render-prompt (make-continuation-prompt-tag 'configkit-render))

;; sink-box: the current emit target; policy-box: 'abort | 'placeholder.
(struct render-ctx (sink-box policy-box))

;; Applies the engine's unfilled policy only when the caller did not supply
;; a fail argument — an explicit fail keeps the ordinary ref contract.
;; Stacked over the recording source, so every read (and every unfilled
;; read) is on record before the policy acts.
(struct policy-source (inner ctx)
  #:methods gen:config-source
  [(define/generic ref config-source-ref)
   (define/generic suite-of config-source-suite)
   (define/generic explicit? config-source-explicit?)
   (define/generic keys-of config-source-keys)
   (define (config-source-suite s) (suite-of (policy-source-inner s)))
   (define (config-source-ref s key [fail-result source-missing])
     (define v (ref (policy-source-inner s) key source-missing))
     (cond
       [(not (eq? v source-missing)) v]
       [(not (eq? fail-result source-missing))
        (if (procedure? fail-result) (fail-result) fail-result)]
       [(eq? (unbox (render-ctx-policy-box (policy-source-ctx s))) 'abort)
        (call-with-composable-continuation
         (lambda (k) (abort-current-continuation render-prompt k key))
         render-prompt)]
       [else (unfilled-placeholder key)]))
   (define (config-source-explicit? s key)
     (explicit? (policy-source-inner s) key))
   (define (config-source-keys s)
     (keys-of (policy-source-inner s)))])

;; --- the driver ------------------------------------------------------------

(struct render-result (verdict product report) #:transparent)

;; Run the application's renderer — (renderer src emit) or, at arity 3,
;; (renderer src emit rec) — over a recording view of the resolved with
;; probed values fed in.  #:mode 'lenient (default): unfilled reads render
;; as placeholders and the verdict stays 'ok, diagnostics in the report.
;; #:mode 'checked: any unfilled read fails the render; no partial product
;; survives, and the single pass still collects every missing field.
;; #:probes #f probes on the spot; pass a record to inject.
(define (call-renderer c renderer
                       #:mode [mode 'lenient]
                       #:writer [w #f]
                       #:probes [pr #f]
                       #:function [function 'render])
  (unless (memq mode '(lenient checked))
    (raise-argument-error 'call-renderer "(or/c 'lenient 'checked)" mode))
  ;; Two-pass for unresolved input: pure resolve → probe (or take the
  ;; injected record) → resolve again with the record injected, so the
  ;; posterior validators run as environment evaluators.  A pre-resolved
  ;; input is taken as-is — its posterior phases already ran.
  (define-values (r probes)
    (cond
      [(resolved? c) (values c (or pr (probe-fields c)))]
      [else
       (define pr* (or pr (probe-fields (resolve c))))
       (values (resolve c #:probes pr*) pr*)]))
  (define wr (or w (make-string-writer)))
  (define-values (rsrc rec) (make-recording-source (with-probes r probes)))
  (define ctx (render-ctx (box (render-writer-emit wr))
                          (box (if (eq? mode 'checked) 'abort 'placeholder))))
  (define psrc (policy-source rsrc ctx))
  (define aborted? (box #f))
  (define (emit s) ((unbox (render-ctx-sink-box ctx)) s))
  (define (run thunk)
    (call-with-continuation-prompt
     thunk render-prompt
     (lambda (k key)
       (set-box! aborted? #t)
       ((render-writer-discard wr))
       (set-box! (render-ctx-sink-box ctx) void)
       (set-box! (render-ctx-policy-box ctx) 'placeholder)
       (run (lambda () (k (unfilled-placeholder key)))))))
  (run (lambda ()
         (if (procedure-arity-includes? renderer 3)
             (renderer psrc emit rec)
             (renderer psrc emit))))
  (define product (and (not (unbox aborted?)) ((render-writer-finish wr))))
  (define verdict
    (if (and (eq? mode 'checked)
             (or (unbox aborted?) (pair? (record-unfilled rec))))
        'failed
        'ok))
  (render-result verdict product
                 (make-report #:function function #:resolved r
                              #:record rec #:source r #:probes probes)))
