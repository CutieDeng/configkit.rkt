# configkit

English | [中文](README.zh.md)

configkit is a minimal, friendly, ergonomic configuration-file framework.

## Minimal: one complete example

`jobs/nightly.config` — one field per line; value positions are data, never
evaluated:

```racket
[spec-src () "/opt/cpu2026"]
[copies  ((default 2) (validate (integer-between 1 64)))]
[tune    ((default "base") (validate (one-of "base" "peak")))]
```

Load and read from the application:

```racket
(require configkit/main)

(parameterize ([current-config-search-heads (hash 'jobs "/srv/myapp/jobs")])
  (define r (resolve (load-config "@jobs/nightly")))
  (resolved-value r 'spec-src)   ; => "/opt/cpu2026"
  (resolved-value r 'copies))    ; => 2 (the default applies)
```

A value can also be computed: `(compute (lambda (v) …))` goes in the
property group with the value position left empty, and the result ranks
with hand-written values (it beats a default). The lambda runs sandboxed
and can query only sibling fields (`config-source-ref`) and the host probe
record (`config-probe-ref`):

```racket
#:extends "nightly"
[copies (override (compute (lambda (v) (- (config-probe-ref v 'host-ncpus 2) 1))))]
```

With no probe record the field stays unfilled (`'awaiting-probes`);
`(resolve c #:probes pr)` settles it, and the expression text goes into
provenance with the value.

## Friendly: when the configuration is wrong

`jobs/bad.config` extends the file above, with two mistakes:

```racket
#:extends "nightly"
[tune   (override) "peek"]
[copies (override) 128]
```

The application's error exit:

```racket
(define r (resolve (load-config "@jobs/bad")))
(unless (resolved-ok? r)
  (display (explain-resolved r))
  (exit 1))
```

The user sees (actual output; glossary: 给定 given, 期望 expected, 提示
hint, 值来自 value from, 验证器于 validator at) — all errors at once, each
with line-level origins for value and validator, a hint for the misspelled
enum:

```text
错误 (2):
  ✗ copies: 超出闭区间
    给定:     128
    期望:     (1 .. 64)
    值来自:   bad @ @jobs/bad.config:3
    验证器于: @jobs/nightly.config:2
  ✗ tune: 不在枚举集内
    给定:     "peek"
    期望:     ("base" "peak")
    提示:     是否想要 "peak"？
    值来自:   bad @ @jobs/bad.config:2
    验证器于: @jobs/nightly.config:3
```

## Ergonomic: configuration that is not wrong, but not right either

`jobs/sloppy.config` — a required field unfilled, one misspelled member in
the `env:` family, and `copies` misspelled as `copise`:

```racket
#:extends "nightly"
[hw-avail (introduce required)]
[env:OMP_NUM_THREADS  (introduce) "8"]
[env:GOMP_CPU_AFFINITY (introduce) "0-63"]
[env:OMP_NUM_THREAD  (introduce) "4"]
[copise (introduce) 16]
```

Unfilled is not an error but a first-class state; the verdict belongs to
the application. Run the consumer on a recording view and the true read and
usage behavior all goes on record:

```racket
(define r (resolve (load-config "@jobs/sloppy")))
(resolved-ok? r)          ; => #t
(unfilled-fields r)       ; => #hasheq((hw-avail . required))

(debug-consume r
  (lambda (src rec)
    (define (ref k) (config-source-ref src k (lambda () (format "<unfilled:~a>" k))))
    (define envs (config-source-ref-group src 'env:))   ; wildcard: the whole env: family
    (record-mark-read! rec 'tune "decided by a runtime probe; deliberately unread here")
    (format "run --src=~a --copies=~a --hw=~a ~a"
            (ref 'spec-src) (ref 'copies) (ref 'hw-avail)
            (string-join (for/list ([k (in-list (sort (hash-keys envs) symbol<?))])
                           (format "--env ~a=~a" k (hash-ref envs k))))))
  #:function 'render-cmdline)
```

which prints (actual output; glossary: 读集 read set, 未填读取 unfilled
reads, 标记 marks, 未读字段 unread fields):

```text
―― render-cmdline
读集: (env:OMP_NUM_THREADS env:GOMP_CPU_AFFINITY env:OMP_NUM_THREAD spec-src copies hw-avail)
未填读取: (hw-avail)
标记: ((tune decided by a runtime probe; deliberately unread here))
未读字段: (copise)
```

Item by item for the user: `hw-avail` was read but has no value (the output
already carries a placeholder); all three `env:` members were genuinely
read by the sweep; not reading `tune` was declared, reason on record;
`copise` was set but never read — did you mean `copies`? Any value's origin
is one call away:

```racket
(peek-field r 'copies)
;; copies = 2
;;   defaulted  nightly @ @jobs/nightly.config:2
```

The sweep matches by prefix, so the misspelled `env:OMP_NUM_THREAD` was
used in earnest too. Declare a whitelist guard and compose it in parallel
with any config; unsupported members go into the warnings (`require-known`
is the error-severity twin); renamed or removed members registered with
`#:renamed` fail by name with the new name or a note:

```racket
(define-config env-guard
  #:validate/post (warn-unknown 'env: 'env:OMP_NUM_THREADS 'env:GOMP_CPU_AFFINITY))

(display (explain-resolved (resolve (config (load-config "@jobs/sloppy") env-guard))))
```

```text
警告 (1):
  ✗ %config: 族内字段 env:OMP_NUM_THREAD 不受支持；是否想要 env:OMP_NUM_THREADS？
    验证器于: app.rkt:4
未填字段 (1):
  hw-avail（required）
```

Problems discovered while consuming are flagged with `record-flag!`; they
land under the report's `'flags` key, warning-severity by default.

## App-layer practice checklist

- **Production consumption loop**: `consume/record` runs the consumer and
  returns the result plus the canonical report; `write-report` archives it:

  ```racket
  (define-values (output report) (consume/record r render #:function 'render))
  (write-report report "run.rktd")
  ```

  While developing, switch to `debug-consume`: same convention, plus a
  printout of reads/marks/flags (the previous section's output came from
  it).
- **Choosing the unfilled `fail` policy**: renderers pass a
  placeholder-returning procedure; strict checkers pass a raising one;
  presence probes use the default sentinel `source-missing`.
- **Test injection**: a fake `.config` tree = point
  `current-config-search-heads` at a stand-in directory; a fake code
  base-config = rebind the same head name to a stand-in registry
  namespace. Config text unchanged, one `parameterize` each.
- **Choosing a scale**: `(config c (hash 'k v))` is for tests and simple
  overlays only; at scale, write `define-config` or `.config`.
- **Downstream of reports**: the `.rktd` is a single `read`-able datum —
  test code reads it back and asserts; CI gates on `(check-config c)`,
  which prints the expansion and returns `#f` when unhealthy.
- **Severity norm**: guards and `record-flag!` default to warnings;
  escalating to errors (`require-known`, `#:severity 'error`) is a
  deliberate act.

---

For internals (module map, the six declaration axes, the security model,
the pitfall list) see [contribute.en.md](contribute.en.md); run the tests
with `raco test tests/`.

At run time the only dependencies are `base` and `sandbox-lib` (evaluating
`.config` closed positions), so a minimal install is never dragged into
downloading documentation packages. The manual is pre-rendered on full Racket
with `./build-docs.sh`, producing self-contained HTML. The trade-off is
recorded in [contribute.en.md](contribute.en.md) §5.
