;; SPDX-License-Identifier: PMPL-1.0-or-later
(state
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-20")
    (status active))
  (project-context
    (name "docudactyl")
    (purpose "Multi-format HPC document extraction engine — British Library scale")
    (completion-percentage 95))
  (components
    (component "chapel-hpc"
      (status "complete")
      (description "Chapel distributed processing engine: Config, ContentType, FFIBridge, ManifestLoader, NdjsonManifest, FaultHandler, ProgressReporter, ShardedOutput, ResultAggregator, Checkpoint, DocudactylHPC"))
    (component "zig-ffi"
      (status "complete")
      (description "Unified Zig FFI dispatcher with 9 submodules: docudactyl_ffi, stages, capnp, cache, dragonfly, prefetch, conduit, gpu_ocr, hw_crypto, ml_inference"))
    (component "processing-stages"
      (status "complete")
      (description "20 processing stages with Cap'n Proto binary output: language, readability, keywords, citations, OCR confidence, perceptual hash, TOC, multi-lang OCR, subtitles, PREMIS, Merkle proof, exact dedup, near dedup, coordinates, NER, Whisper, image classify, layout, handwriting, format convert"))
    (component "caching"
      (status "complete")
      (description "Two-level cache: L1 LMDB per-locale (zero-copy mmap, 10GB/locale) + L2 Dragonfly cross-locale (RESP2, SHA-256 keyed). Conduit pre-computes SHA-256 for L2 on cold runs"))
    (component "conduit"
      (status "complete")
      (description "Preprocessing pipeline: magic-byte content detection (15 formats), file validation, SHA-256 pre-computation, file size capture. Eliminates stat() calls and invalid-file parse attempts"))
    (component "gpu-ocr"
      (status "integrated")
      (description "GPU OCR coprocessor: runtime backend detection via dlopen (PaddleOCR CUDA/TensorRT > Tesseract CUDA > CPU). Per-image GPU dispatch in parse path with CPU fallback"))
    (component "ml-inference"
      (status "integrated")
      (description "ONNX Runtime ML engine: 5 stages (NER, Whisper, ImageClassify, Layout, Handwriting). Auto-selects TensorRT > CUDA > OpenVINO > CPU. Lazy model loading, dispatched from stage pipeline"))
    (component "hw-crypto"
      (status "complete")
      (description "Hardware crypto acceleration: CPUID/HWCAP detection (SHA-NI, AVX2, AVX-512, AES-NI, ARM SHA2). Multi-buffer SHA-256 (4-lane interleaved I/O)"))
    (component "io-prefetcher"
      (status "complete")
      (description "Async I/O prefetcher: io_uring on Linux 5.6+, posix_fadvise fallback. Sliding window of upcoming files"))
    (component "ndjson-manifests"
      (status "complete")
      (description "Enriched NDJSON manifests with pre-computed size/mtime/kind. Auto-detect format from first line. Eliminates 170M stat() calls"))
    (component "capnp-output"
      (status "complete")
      (description "Cap'n Proto binary serialisation for stage results. Minimal single-segment builder, no external deps"))
    (component "idris2-abi"
      (status "complete")
      (description "Formal ABI types with genuine proofs: ContentKind, ParseStatus, ParseResult (952B), OcrResult (48B), ConduitResult (88B), OcrStatus, GpuBackend, ConduitValidation"))
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
    (hot-path "Chapel → Conduit → L1/L2 Cache → Zig FFI → C libraries (Poppler, Tesseract/GPU OCR, FFmpeg, libxml2, GDAL, libvips) → Stages → ONNX Runtime ML")
    (offline-path "OCaml docudactyl-scm: extracted JSON/text → Scheme S-expressions")
    (scale-target "170M items across all formats (British Library)")
    (locale-range "64-512 nodes")
    (zig-modules "docudactyl_ffi, stages, capnp, cache, dragonfly, prefetch, conduit, gpu_ocr, hw_crypto, ml_inference")
    (dlopen-deps "ONNX Runtime, PaddleOCR, LMDB, libcudart — no link-time requirements"))
  (performance-estimates
    (cold-run "3.7h at 256 nodes + GPU for 170M items")
    (warm-run "4.4 min at 256 nodes with L1+L2 cache")
    (incremental "8 min at 256 nodes for 5% new files"))
  (maintenance
    (corrective "Min image dimension check, rpath fix, manifest off-by-one, error message propagation, MlResult size fix (48 not 56)")
    (adaptive "Version pinning, deps-check, compile-time checks, broadcast manifest mode, Chapel version guard")
    (perfective "Cap'n Proto stages, NDJSON manifests, two-level caching, conduit, GPU OCR, ML inference, hw crypto, io_uring prefetch, handle attachment pattern"))
  (blockers
    (blocker "multi-locale-testing"
      (description "Requires cluster access to test -nl 4+ on real GASNet/IBV network"))))
