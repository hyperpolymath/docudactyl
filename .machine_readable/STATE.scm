;; SPDX-License-Identifier: PMPL-1.0-or-later
(state
  (metadata
    (version "0.3.0")
    (last-updated "2026-02-20")
    (status active))
  (project-context
    (name "docudactyl")
    (purpose "Multi-format HPC document extraction engine — British Library scale")
    (completion-percentage 90))
  (components
    (component "chapel-hpc"
      (status "complete")
      (description "Chapel distributed processing engine: Config, ContentType, FFIBridge, ManifestLoader, FaultHandler, ProgressReporter, ShardedOutput, ResultAggregator, Checkpoint, DocudactylHPC"))
    (component "zig-ffi"
      (status "complete")
      (description "Unified Zig FFI dispatcher with compile-time version checks: PDF (Poppler), Image (Tesseract), Audio/Video (FFmpeg), EPUB (libxml2), GeoSpatial (GDAL)"))
    (component "idris2-abi"
      (status "complete")
      (description "Formal ABI types with genuine proofs (no believe_me): ContentKind, ParseStatus, ParseResult, layout proofs, platform proofs"))
    (component "checkpoint-resume"
      (status "complete")
      (description "Per-locale checkpoint files, resume from previous run, configurable flush interval"))
    (component "cluster-deployment"
      (status "complete")
      (description "Containerfile (Wolfi runtime), Slurm job script, GASNet/IBV config"))
    (component "testing"
      (status "complete")
      (description "Integration tests, error path tests, scale test (2105 files, 19.35 docs/s, 0 failures)"))
    (component "build-system"
      (status "complete")
      (description "Justfile: build-hpc, deps-check, test-ffi, test-error-paths, test-scale, .tool-versions"))
    (component "ocaml-scm"
      (status "stable")
      (description "Offline Scheme transformer: PDF/JSON to S-expressions (not in HPC hot path)"))
    (component "ada-tui"
      (status "stable")
      (description "Terminal UI for document inspection"))
    (component "julia-legacy"
      (status "legacy")
      (description "Julia extraction scripts — replaced by Chapel HPC pipeline")))
  (architecture
    (hot-path "Chapel → Zig FFI → C libraries (Poppler, Tesseract, FFmpeg, libxml2, GDAL, libvips)")
    (offline-path "OCaml docudactyl-scm: extracted JSON/text → Scheme S-expressions")
    (scale-target "170M items across all formats (British Library)")
    (locale-range "64-512 nodes"))
  (maintenance
    (corrective "Min image dimension check, rpath fix, manifest off-by-one, error message propagation")
    (adaptive "Version pinning, deps-check, compile-time checks, broadcast manifest mode, Chapel version guard")
    (perfective "Checkpoint/resume, JSON report output, structured logging"))
  (blockers
    (blocker "multi-locale-testing"
      (description "Requires cluster access to test -nl 4+ on real GASNet/IBV network"))))
