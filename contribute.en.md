# Contributing: core modules and design principles

English | [中文](contribute.zh.md)

For usage, read [README.en.md](README.en.md) first. This document explains
how the code is organized and why it is designed this way. The semantic
ground truth lives in the parent runspeccpu repository:
`docs/config-refactor.md` (semantics), `docs/config-examples.md` (syntax),
`docs/render-flow.md` (consumer execution flow) — **semantic questions defer
to docs, usage questions defer to the README and the tests**.

## 1. Module map

Dependencies point strictly downward, no cycles; `main.rkt` re-exports
everything.

| Module | Responsibility | Key exports |
|---|---|---|
| `source.rkt` | Consumption protocol: the minimal common surface of every config representation | `gen:config-source` (`suite`/`ref`/`explicit?`/`keys`), the `source-missing` sentinel |
| `config.rkt` | Kernel: definition, composition, resolution | `define-config`, `config`, `resolve`, the query surface (`resolved-*`, `provenance-ref`), verdict constructors (`fail`/`warn`/`skip`) |
| `loader.rkt` | The `.config` grammar: parsing + sandbox + containment checks | `load-config`, `current-config-search-heads`, `current-config-registry` |
| `validators.rkt` | Declarative check combinators (rich verdicts built in, injected into the `.config` sandbox) | `one-of`, `integer-between`, `require-filled`, ... |
| `record.rkt` | Read recording, canonical `.rktd` reports, human-facing expansion | `make-recording-source`, `make-report`, `explain-resolved` |
| `debug.rkt` | Application-side dev helpers (thin veneers over the query surface, zero new mechanism) | `peek`, `peek-field`, `check-config`, `debug-consume`, `list-configs` |
| `main.rkt` | One-stop re-export | — |

Planned (interfaces settled, not started): `probe.rkt` (probe records) and
`render.rkt` (writer interface, suspend/resume of failure paths via delimited
continuations); design in `docs/render-flow.md`.

### The principle behind each module

**`source.rkt` — protocol before representation.** The library knows no
application; the dependency direction is always application → library.
Consumers (renderers, executors) read only through `gen:config-source`.
The `ref` contract: an explicit `false` is a value, not absence; on absence
the `fail` argument decides (a value is returned as-is, a procedure is
called, the default returns the `source-missing` sentinel) — **the policy
for unfilled fields belongs to the consumer, not to the library**. The
protocol also carries a wildcard read, `config-source-ref-group`
(prefix/regexp sweep over a field family, each member a genuine ref,
returning the filled matches; unfilled fields are not enumerable and are
never touched).

**`config.rkt` — a config is a partial record; declarations are voluntary
checks.** Unfilled fields are a first-class state (not `#f`, not a
sentinel); a config may still have unfilled fields after `resolve`
(`noneager`). Field declarations run along six axes, all with defaults:
the intent axis `{introduce,override}`, the introduction axis `singlenew`,
the sealing axis `open`, the eagerness axis `noneager`, etc. — an empty
property group `()` means all defaults, and writing `(override)` or
`(sealed)` **buys exactly one extra check**; it is never mandatory syntax.
The two composition relations have different semantics: `#:extends` is a
chain (changing an inherited value requires `override`); `(config a b)` is
parallel unification (unordered, commutative; same field with different
concrete values = conflict error, and **there is no force** — fix the source
or demote one side to a `default`). The resolution pipeline has five gated
stages: merge → ① immediate validation → ② computed defaults (lazy, with
cycle detection; a field on a detected cycle is poisoned and never gets a
value) → ③ per-field posterior validation → ④ global posterior validation.
Errors within a stage **accumulate and report all at once**; a stage with
errors gates all later stages; collected warnings are always kept. The
semantic layer never pushes: provenance, read sets, and skipped validators
are passive records — query what you need.

**`loader.rkt` — parse, execute nothing.** The `.config` grammar has no
top-level code position; value positions are data literals, read but never
evaluated (a lambda-shaped list is just data). Expressions exist only in the
two closed positions (`validate`/`default`), whose contract is
"expression → procedure", evaluated inside `racket/sandbox` (time/memory
limits + security guard); every closure call re-enters the sandbox, so the
limits apply at call time, not just at load time. Path references allow no
`..` and no absolute paths; containment checking is two-stage (lexical
normalization, then per-component symlink resolution — both must stay inside
the equally-resolved root). The head table and the registry are **not
configuration data** (no self-privilege-escalation): the loader holds them,
the host registers them, downstream configs can use but never extend them.
Fake heads and registry rebinding are exactly the test-injection mechanism —
reroot at the data layer, never stub at the code layer.

**`validators.rkt` — rich verdicts; guess for the user.** A validator
returns `#t`/`(void)` to pass, `(fail #:reason ... #:expected ... #:given
... #:hint ...)` to fail, or a list to accumulate several verdicts; `one-of`
has an edit-distance "did you mean" hint built in. Validators can only be
appended, never replaced (downstream tightening is legal); relaxation goes
only through an `env` field plus a posterior validator deciding `skip` for
itself. A validator returning a non-protocol value (e.g. the symbol `'fail`
by mistake) records a `validator-protocol` warning — neither silently
passing nor failing the config. The posterior combinators come in
directional pairs: `require-filled`/`warn-unfilled` ask "is everything I
need there", `require-known`/`warn-unknown` ask the reverse — "is
everything there something I support" (a family whitelist, the natural
companion of the wildcard read). Severity norm: **default to the warning
variants**; the require (error-severity) variants are for deliberate
hardening — the consumption-time flag `record-flag!` defaults to warning
under the same norm.

**`record.rkt` — one readable datum is the canonical form.** A report is a
single `.rktd` datum (no closures, no opaque structs); the human-facing
expansion (`explain-resolved`) is a derived view of the same data, never a
second source of truth. Every error carries four things: given, expected,
hint, and provenance (the line the value came from plus the line the
validator came from). The read record keeps three kinds of entries: genuine
refs in the read set; unfilled reads as a **roster** (that a read hit an
unfilled field is the signal; how many times carries no information); and
application marks (`record-mark-read!` — consumption the recording source
cannot observe, or deliberate ignoring, with a reason that lands in the
report: auditable, not an exemption). Unread-field detection counts both
genuine reads and marks as consumption. Consumption-time verdicts go
through `record-flag!` (a problem discovered only while using a value;
severity defaults to warning, escalating to error is a deliberate act;
lands under the report's `'flags` key). The production consumption loop is
one call, `consume/record` (resolve, record, consume, report), and
`debug.rkt`'s `debug-consume` is its printing shell — the convenient path
is the correct path. The report format evolves independently via its
`format-version` field.

**`debug.rkt` — the thin-veneer discipline.** Every dev helper is a
composition of public query surfaces: nothing extra recorded, nothing on the
production path. If a debugging need cannot be met by a thin veneer, that is
a gap in the kernel's query surface — fill the query surface first.

## 2. Invariants (read before changing code)

1. Library modules **must not require application code**; `tests/`
   implements the protocol with toy representations, which is the executable
   check of this discipline.
2. Public interfaces follow the vN contract: published keywords are only
   added, never removed; defaults never change; semantics never change
   (`docs/config-refactor.md` §3.5).
3. The `suite` field has no special kernel semantics: it is an ordinary
   field plus a convenience accessor on the protocol (degrading to
   `'unknown` when absent); "two suites cannot mix" is an emergent property
   of `singlenew` + unification, not a special case.
4. `id` is the name (the `define-config` binding name / the `.config` file
   name) and does not travel down chains; `class` is a convention, not a
   mechanism (ordinary-field inheritance/override/sealed all apply).
5. Every behavior change needs a regression case in `tests/*-test.rkt`;
   **reading the tests is the fastest second entry point** — keep that true.

## 3. Pitfalls (all genuinely hit during development)

1. **Value positions differ between `.rkt` and `.config`**: in `.rkt` they
   are expressions (write `(list 1 2)`); in `.config` they are read, not
   evaluated (`(1 2)` is list data).
2. **Closed positions do execute combinator applications at load time**
   (sandboxed): `(validate (one-of ...))` calls `one-of` during loading;
   the `default` position accepts only data literals or `(lambda ...)`
   (decided by shape), so combinator factories do not apply to `default`.
3. **Parallel ≠ override**: `(config job (hash 'copies 100))` is a parallel
   conflict ⊥; to change a value, write `#:extends` + `(override)`.
4. **`singlenew` is the default**: two unrelated configs each `introduce`-ing
   the same field is an error even with equal values; declare
   `multi-introducer` if you truly want multiple introducers.
5. **Explicit `false` is a value**: after `[dryrun () false]`, `ref`
   returns `#f`, not absence.
6. **Warnings never affect `resolved-ok?`**; they live in their own table,
   `resolved-warnings`.
7. **Stage gating swallows later-stage checks**: in tests, never put
   "provoke an error" and "verify later-stage behavior" into the same
   config.
8. **When upstream has only a default**, `(override)` is legal (a default is
   a legal override target), and a bare `()` downstream also takes effect
   directly.
9. **Hash coercion is the most permissive** (includes `multi-introducer`)
   and its provenance degrades to fragment granularity — use it only for
   simple overlays; write `define-config` or `.config` at scale.
10. **Loader references have no upward paths**: `"../x"`, `"/abs"`,
    `"a//b"` are all rejected (`string-split` must use `#:trim? #f`; there
    was a real silent-downgrade hole for absolute paths here); containment
    is two-stage, so an in-root symlink pointing outside is rejected too.
11. **Booleans in `.config` are `true`/`false` only**: raw `#t`/`#f` is
    rejected at load time.
12. **A report's `values` contains filled fields only**: unfilled ones live
    under the `unfilled` key; there is no placeholder symbol, so a field
    whose value happens to be `'<unfilled>` cannot be confused.
13. **`config.rkt`'s `fail` collides with rackunit's**: in tests, write
    `(require (except-in rackunit fail) ...)`.

## 4. Development loop

```sh
raco test tests/          # full run; one *-test.rkt per module
```

Kernel changes → run `config-test`; grammar/sandbox/path changes → run
`loader-test`; report-shape changes → run `record-test` and consider whether
`format-version` needs to move.
