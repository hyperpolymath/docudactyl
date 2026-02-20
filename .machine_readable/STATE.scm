;; SPDX-License-Identifier: PMPL-1.0-or-later
(state
  (metadata
    (version "0.2.0")
    (last-updated "2026-02-20")
    (status active))
  (project-context
    (name "docudactyl")
    (purpose "Multi-format HPC document extraction engine — British Library scale")
    (completion-percentage 35))
  (components
    (component "chapel-hpc"
      (status "implemented")
      (description "Chapel distributed processing engine: Config, ContentType, FFIBridge, ManifestLoader, FaultHandler, ProgressReporter, ShardedOutput, ResultAggregator, DocudactylHPC"))
    (component "zig-ffi"
      (status "implemented")
      (description "Unified Zig FFI dispatcher: PDF (Poppler), Image (Tesseract), Audio/Video (FFmpeg), EPUB (libxml2), GeoSpatial (GDAL)"))
    (component "idris2-abi"
      (status "implemented")
      (description "Formal ABI types with proofs: ContentKind, ParseStatus, ParseResult, layout proofs for ddac_parse_result_t"))
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
    (locale-range "64-512 nodes")))
