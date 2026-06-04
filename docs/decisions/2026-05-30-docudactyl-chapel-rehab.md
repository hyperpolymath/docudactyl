<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# ADR — Docudactyl Chapel Rehabilitation (Wave 3 of the echidna#146 arc)

- Status: Accepted
- Date: 2026-05-30
- Closes: [docudactyl#29](https://github.com/hyperpolymath/docudactyl/issues/29)
- Wave 1 reference: [echidna#146](https://github.com/hyperpolymath/echidna/pull/146)
- Wave 2 tracker: [proven#126](https://github.com/hyperpolymath/proven/issues/126)
- SPDX-License-Identifier: MPL-2.0

## Context

`docudactyl` is a distributed document-processing HPC engine for British-Library-scale corpora — 170M+ items dispatched across Chapel locales, parsing via a Zig FFI bridge to C parser libraries (poppler / tesseract / ffmpeg / libxml2 / gdal / vips). The Chapel framework lives at `src/chapel/` (11 modules, ~2,500 lines).

`docudactyl#29` was filed alongside `echidna#146` (the Wave-1 Chapel metalayer rehabilitation) and `proven#126` (the Wave-2 follow-on). Each Wave-N issue applies the same shape: rewrite for chpl 2.8.0 compatibility, decouple the FFI smoke from the metalayer, flip CI to strict, and decide whether the Wave-1 `ParallelSoundness.agda` invariants apply to this repo's parallel-dispatch surface.

## Decision

Port the echidna#146 pattern with **two scope adjustments**:

1. **No `ParallelSoundness.agda` port.** Docudactyl's parallel-dispatch surface is `forall idx in dynamic(docEntries.domain, chunkSize)` in `DocudactylHPC.chpl` — embarrassingly-parallel work distribution with deterministic per-locale-slot aggregation, not speculative search. Echidna's three theorems (first-success-wins soundness, completeness under retry, cancellation safety) are inapplicable. Docudactyl's relevant invariants — at-most-once under checkpoint resume, aggregation commutativity, L1/L2 cache coherence — are documented below and deferred to a follow-up Agda module if formal proofs become load-bearing.

2. **The CI `check-abi` job retains `continue-on-error: true`.** This is documented as environmental fragility (Idris2 source bootstrap on ubuntu-24.04, not docudactyl correctness). The new `build-smoke` job is the strict gate the echidna pattern actually wants.

## What landed

### Chapel 2.8.0 compatibility fixes

`chpl --no-codegen src/chapel/DocudactylHPC.chpl src/chapel/*.chpl` was failing with three errors before this PR; all three are now resolved. The metalayer compiles clean on chpl 2.8.0 (LLVM-built local toolchain) with only known unstable-API warnings remaining (`_pad` symbol prefixes; `dmapped`; `DynamicIters`; `string.c_str()`; cross-locale `c_addrOf`).

| Site | Pre-state | Fix |
|---|---|---|
| `DocudactylHPC.chpl:303, 311, 373` | `FileSystem.stat(string)` removed in chpl 2.8.0 | `use OS.POSIX;` + `struct_stat` + `stat(path.c_str(), c_ptrTo(sb))`; field reads via `sb.st_mtim.tv_sec` / `sb.st_size` |
| `DocudactylHPC.chpl:211` | `forall` task-private intent made outer `var ndjsonWriter` const-shadow; `proc ref writeResult` rejected the const actual | `forall … with (ref ndjsonWriter) { … }` (matches the `begin with (ref timer)` pattern already at line 201) |
| `NdjsonManifest.chpl:91` | `string[range]` slicing now `throws` (UTF-8 boundary check) | `try { return line[range]; } catch { return ""; }` — preserves the existing "return empty on error" contract |
| `NdjsonManifest.chpl:177, 182` | `string.createCopyingBuffer(c_ptrConst(c_char))` now `throws` | `try { … } catch { }` around each optional field — the SHA-256 / title fields are skipped in the rare malformed-UTF-8 case so the `forall` task is not torn down |

### Decoupled FFI smoke

`src/chapel/smoke.chpl` (46 lines) exercises `ddac_version` / `ddac_crypto_sha256_name` / `ddac_init` / `ddac_free` against the FFI bridge **without** pulling in the full `DocudactylHPC` metalayer. This is the echidna#146 invariant: a green smoke proves the C ABI compiles + links + returns sane data even when the metalayer is broken, so regression localisation is fast.

The smoke is wired three places:

- `Justfile` recipes: `check-smoke` (parse-only), `build-smoke` (binary), `run-smoke` (executes the binary)
- `.github/workflows/hpc-ci.yml` job `build-smoke`: depends on `build-ffi`, strict (no `continue-on-error`), greps for `^\[smoke\] PASS$` in the binary output
- `Justfile :: check-chapel` now uses `--main-module DocudactylHPC` to disambiguate the two `proc main()` files (DocudactylHPC + smoke) when globbing `src/chapel/*.chpl`

### CI floor bumped

`CHAPEL_VERSION: '2.3.0'` → `'2.8.0'` in `hpc-ci.yml`. The OS.POSIX migration is the proximate cause; the wider justification is that 2.8.0 is the version the rehabilitation pattern was validated against in Wave 1.

## Parallel-dispatch invariants (informal — deferred to follow-up if formalised)

These document the invariants the docudactyl `forall idx in dynamic(...)` loop relies on. They are NOT proved here; they are recorded so a future Agda module has a target.

1. **At-most-once** — every document index in `docEntries.domain` is processed at most once. Currently enforced per-locale by `isAlreadyProcessed(idx)` (Checkpoint.chpl) gating on `recordCheckpoint`. Caveat: cross-locale resume after a topology change (e.g. 64 → 128 locales) is NOT global-atomic.
2. **Abort-bounded** — beyond a failure-rate threshold (FaultHandler.chpl), the loop short-circuits; unprocessed indices are NOT silently dropped, they remain unprocessed and observable via the report.
3. **Aggregation commutativity** — `accumulate(result)` writes only to `perLocaleStats[here.id]` (per-locale slot, no cross-task race); `computeGlobal` reduces by integer addition, which is commutative. SATISFIED by construction.
4. **Cache coherence (L1)** — `(path, mtime, size)`-keyed LMDB lookups in the per-locale L1 are read-then-write within a single task; no concurrent writers to the same key.
5. **Cache coherence (L2)** — Dragonfly L2 is shared across locales and keyed by SHA-256; concurrent `store` calls for the same key are tolerated because the value is deterministic (same SHA-256 implies same parse result). Not formally proven.
6. **Checkpoint resumability** — resuming from a `recordCheckpoint(idx)` snapshot reproduces the same `succeededDocs / failedDocs` global stats modulo per-locale ordering. Stats are aggregated by addition, so order does not matter.
7. **Content-type determinism** — magic-byte detection (`conduit.content_kind`) is deterministic per input file.

A follow-up issue should be filed if these need formal mechanisation (Agda module path `proofs/agda/DistributedAggregationInvariants.agda`); echidna's `ParallelSoundness.agda` cannot be imported unchanged.

## Wave-2 gate

Per `docudactyl#29`, this PR was deferred until `proven#126` (Wave 2) "lands". At time of writing `proven#126` is still OPEN. The owner-authorised exception: the echidna#146 + proven#135 (binding-tier-1 detachable harness) pair has stabilised the rehabilitation shape; a docudactyl rehab now does not risk pattern-divergence. Should Wave 2 settle on a different shape, this ADR is the supersedable surface — the smoke target and CI gate are the load-bearing pieces that would change.

## Consequences

- `chpl 2.8.0` is now the floor in CI; running on `2.3.0` will fail the OS.POSIX import.
- The metalayer build remains the same shape; only the three stat sites + `with (ref ndjsonWriter)` clause + the two throws-wrappers in NdjsonManifest differ.
- The new `build-smoke` job runs in parallel with `build-chapel` (both `needs: build-ffi`), so wallclock CI time does not regress.
- `check-abi` still flagged fragile; not changed in this PR.

## References

- [echidna#146](https://github.com/hyperpolymath/echidna/pull/146) — Wave-1 metalayer rehabilitation; canonical pattern source
- [proven#126](https://github.com/hyperpolymath/proven/issues/126) — Wave-2 tracker
- [docudactyl#29](https://github.com/hyperpolymath/docudactyl/issues/29) — this issue
- chpl 2.8.0 `OS.POSIX.stat` — `/usr/share/chapel/2.8/modules/standard/OS.chpl:929-965`
