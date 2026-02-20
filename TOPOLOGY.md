# TOPOLOGY.md — Docudactyl HPC Architecture

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Docudactyl HPC Engine                               │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                  Chapel Orchestrator (N locales)                        │  │
│  │                                                                        │  │
│  │  DocudactylHPC.chpl ──── main entry point, forall loop                │  │
│  │    ├── Config.chpl ───── runtime config (--manifestPath, etc.)        │  │
│  │    ├── ManifestLoader ── load 170M paths (plain or NDJSON)            │  │
│  │    ├── NdjsonManifest ── enriched manifests (size/mtime/kind)         │  │
│  │    ├── ContentType ───── detect format from extension                 │  │
│  │    ├── FaultHandler ──── retry loop, abort detection, timing          │  │
│  │    ├── ProgressReporter  background status on locale 0                │  │
│  │    ├── ShardedOutput ─── output/shard-{localeId}/                     │  │
│  │    ├── ResultAggregator  per-locale → global stats (.scm + .json)     │  │
│  │    └── Checkpoint ────── resume after node failure                    │  │
│  │                                                                        │  │
│  │  forall idx in dynamic(docEntries.domain, chunkSize) {                │  │
│  │    handle = ddac_init()                                               │  │
│  │    ddac_set_ml_handle(handle, mlHandle)       // attach ML engine     │  │
│  │    ddac_set_gpu_ocr_handle(handle, gpuOcr)    // attach GPU OCR       │  │
│  │    conduit = ddac_conduit_process(path)        // validate + SHA-256   │  │
│  │    result  = safeParse(handle, path, out, fmt) // parse + stages       │  │
│  │    accumulate(result)                                                  │  │
│  │  }                                                                     │  │
│  └────────────────────────────┬───────────────────────────────────────────┘  │
│                               │ C FFI (by value, flat struct)                │
│  ┌────────────────────────────▼───────────────────────────────────────────┐  │
│  │                  Zig FFI Dispatcher (zero overhead)                     │  │
│  │                  ffi/zig/src/docudactyl_ffi.zig                        │  │
│  │                                                                        │  │
│  │  ddac_parse() ─── detect format ─── dispatch to C library:            │  │
│  │    ├── .pdf ──────→ Poppler (poppler-glib)                            │  │
│  │    ├── .jpg/.png ─→ GPU OCR → Tesseract (fallback)                    │  │
│  │    ├── .mp3/.wav ─→ FFmpeg (libavformat)                              │  │
│  │    ├── .mp4/.mkv ─→ FFmpeg (libavformat + libavcodec)                 │  │
│  │    ├── .epub ─────→ libxml2                                           │  │
│  │    └── .shp/.tif ─→ GDAL                                             │  │
│  │                                                                        │  │
│  │  Processing Stages (stages.zig + capnp.zig → .stages.capnp)          │  │
│  │    ├── Phase 1: PREMIS, exact dedup, OCR confidence                   │  │
│  │    ├── Phase 2: language, readability, keywords, citations            │  │
│  │    ├── Phase 3: Merkle proof (streaming, O(log n) memory)             │  │
│  │    ├── Phase 4: TOC extract (PDF), subtitle extract (AV)              │  │
│  │    ├── Phase 5: perceptual hash, near dedup, multi-lang OCR           │  │
│  │    ├── Phase 6: coordinate normalize (geospatial)                     │  │
│  │    └── Phase 7: ML stages → ONNX Runtime (NER/Whisper/Layout/etc.)    │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────── Subsystem Modules (Zig, all dlopen, zero link deps) ──────┐ │
│  │                                                                        │  │
│  │  conduit.zig ───── magic-byte detection + file validation + SHA-256   │  │
│  │  gpu_ocr.zig ───── PaddleOCR GPU → Tesseract CUDA → CPU fallback     │  │
│  │  ml_inference.zig  ONNX Runtime (TensorRT > CUDA > OpenVINO > CPU)    │  │
│  │  hw_crypto.zig ─── SHA-NI/AVX2/ARM-SHA2 detection + multi-buffer     │  │
│  │  cache.zig ──────── LMDB L1 per-locale (zero-copy mmap, ACID)         │  │
│  │  dragonfly.zig ─── Dragonfly L2 cross-locale (RESP2, 25x Redis)      │  │
│  │  prefetch.zig ──── io_uring async I/O + posix_fadvise fallback        │  │
│  │  capnp.zig ──────── Cap'n Proto single-segment message builder         │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                  Idris2 ABI Proofs (compile-time)                       │  │
│  │                  src/abi/{Types,Layout,Foreign}.idr                     │  │
│  │                                                                        │  │
│  │  ContentKind ─── 7 variants, injective, decidably equal               │  │
│  │  ParseStatus ─── 7 variants, retryable predicate                      │  │
│  │  ParseResult ─── 952-byte struct, LP64 layout proof                   │  │
│  │  OcrResult ───── 48-byte struct proof                                 │  │
│  │  ConduitResult ─ 88-byte struct proof                                 │  │
│  │  OcrStatus ───── gpu fallback predicate                               │  │
│  │  GpuBackend ──── 3 variants with conversions                          │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────┐  ┌──────────────────────────────────────┐ │
│  │  OCaml (offline, not HPC)    │  │  Ada TUI (standalone)                │ │
│  │  docudactyl-scm              │  │  docudactyl-tui                      │ │
│  │  JSON/text → S-expressions   │  │  Terminal document inspector         │ │
│  └──────────────────────────────┘  └──────────────────────────────────────┘ │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Julia (legacy — replaced by Chapel HPC pipeline)                      │  │
│  │  src/julia/ — extraction, analysis, parallel, CLI                      │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘

Data Flow (hot path):

  manifest ──→ Chapel ──→ Conduit ──→ L1 Cache ──→ L2 Dragonfly ──→ Parse
  (170M paths)  (distribute)  (validate)   (LMDB hit?)  (SHA-256 hit?)  (Zig FFI)
                                │                                          │
                                └── skip invalid ──→ recordFailure()       │
                                                                           ▼
                              output/shard-N/*.{scm,json,csv} ◄──── C parsers
                              output/shard-N/*.stages.capnp   ◄──── stage results
                              output/run-report.scm

Cache Architecture:

  ┌─────────────────────┐     ┌──────────────────────────┐
  │  L1: LMDB per-locale │     │  L2: Dragonfly (shared)   │
  │  Zero-copy mmap      │     │  RESP2 protocol            │
  │  Key: path+mtime+sz  │────→│  Key: SHA-256 hex          │
  │  10GB / locale        │     │  Cross-locale dedup        │
  └─────────────────────┘     └──────────────────────────┘
       ▲                            ▲
       │ Conduit pre-computes       │ Conduit SHA-256 feeds
       │ file_size (no stat)        │ L2 lookup on cold runs
       └────────────────────────────┘

Offline:
  output/*.json ──→ OCaml docudactyl-scm ──→ *.scm (S-expressions)
```

## Completion Dashboard

| Component                  | Status      | Progress                     |
|----------------------------|-------------|------------------------------|
| Chapel HPC Engine          | Complete    | `██████████` 100%            |
| Zig FFI Dispatcher         | Complete    | `██████████` 100%            |
| Processing Stages (20)     | Complete    | `██████████` 100%            |
| Cap'n Proto Output         | Complete    | `██████████` 100%            |
| NDJSON Manifests           | Complete    | `██████████` 100%            |
| Preprocessing Conduit      | Complete    | `██████████` 100%            |
| L1 Cache (LMDB)           | Complete    | `██████████` 100%            |
| L2 Cache (Dragonfly)      | Complete    | `██████████` 100%            |
| I/O Prefetcher (io_uring) | Complete    | `██████████` 100%            |
| GPU OCR Coprocessor        | Integrated  | `██████████` 100%            |
| ML Inference (ONNX)        | Integrated  | `██████████` 100%            |
| Hardware Crypto (SHA-NI)   | Complete    | `██████████` 100%            |
| Idris2 ABI Proofs          | Complete    | `██████████` 100%            |
| C Header (interop)         | Complete    | `██████████` 100%            |
| Checkpoint & Resume        | Complete    | `██████████` 100%            |
| OCaml Scheme Emitter       | Stable      | `██████████` 100%            |
| Ada TUI                    | Stable      | `██████████` 100%            |
| Julia (legacy)             | Deprecated  | `██████████` 100% (frozen)   |
| Multi-Locale Testing       | Not Started | `░░░░░░░░░░` 0%             |

**Overall: `█████████░` 95%** (multi-locale testing requires cluster access)

## Key Dependencies

| Dependency       | Version  | Purpose                              | Link      |
|------------------|----------|--------------------------------------|-----------|
| Chapel           | 2.7.0    | HPC orchestration (N locales)        | build     |
| Zig              | 0.15.2   | FFI wrapper, zero runtime cost       | build     |
| Idris2           | 0.8.0    | ABI formal proofs                    | build     |
| Poppler          | 25.07.0  | PDF text + metadata extraction       | link      |
| Tesseract        | 5.5.2    | OCR (image → text)                   | link      |
| Leptonica        | 1.87.0   | Image I/O for Tesseract              | link      |
| FFmpeg           | 7.1.2    | Audio/video metadata                 | link      |
| libxml2          | 2.12.10  | EPUB/XHTML parsing                   | link      |
| GDAL             | 3.11.5   | Geospatial data extraction           | link      |
| libvips          | 8.17.3   | Image metadata                       | link      |
| ONNX Runtime     | 1.20+    | ML inference (NER, Whisper, etc.)    | dlopen    |
| PaddleOCR        | 3.0+     | GPU OCR (CUDA/TensorRT)              | dlopen    |
| LMDB             | 0.9.33   | L1 result cache (per-locale)         | dlopen    |
| Dragonfly        | 1.25+    | L2 shared cache (RESP2)              | TCP       |
| OCaml            | 5.4.1    | Offline Scheme transformer           | separate  |
| Ada/GNAT         | —        | TUI (terminal inspector)             | separate  |

## Scale Targets

| Metric         | Local Test (verified) | Cluster Target (estimated)  |
|----------------|----------------------|-----------------------------|
| Documents      | 2,105                | 170,000,000                 |
| Locales        | 1                    | 64–512                      |
| Throughput     | 19.35 docs/s         | ~1,200–10,000 docs/s        |
| Failure rate   | 0.0%                 | < 5.0%                      |
| Output size    | ~1 MB                | ~1.7 TB                     |
| Memory/locale  | ~100 MB              | ~4–8 GB                     |
| Cold run       | —                    | ~3.7h (256 nodes + GPU)     |
| Warm run       | —                    | ~4 min (256 nodes, cached)  |
| Incremental    | —                    | ~8 min (5% new, 256 nodes)  |

## Zig Module Architecture

```
docudactyl_ffi.zig (root — C-ABI exports, format dispatch)
  ├── stages.zig        (20 processing stages + Cap'n Proto output)
  ├── capnp.zig         (Cap'n Proto single-segment message builder)
  ├── cache.zig         (LMDB L1 cache — zero-copy mmap)
  ├── dragonfly.zig     (Dragonfly L2 cache — RESP2 protocol)
  ├── prefetch.zig      (io_uring I/O prefetcher + fadvise fallback)
  ├── conduit.zig       (magic-byte detection + SHA-256 pre-compute)
  ├── gpu_ocr.zig       (batched GPU OCR — PaddleOCR/Tesseract CUDA)
  ├── hw_crypto.zig     (SHA-NI/AVX2 detection + multi-buffer hash)
  └── ml_inference.zig  (ONNX Runtime — 5 ML stages via dlopen)
```
