# TOPOLOGY.md — Docudactyl HPC Architecture

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Docudactyl HPC Engine                            │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    Chapel Orchestrator (N locales)                 │  │
│  │                                                                   │  │
│  │  DocudactylHPC.chpl ─── main entry point                         │  │
│  │    ├── Config.chpl ──── runtime config (--manifestPath, etc.)    │  │
│  │    ├── ManifestLoader ─ load 170M paths, block-distribute        │  │
│  │    ├── ContentType ──── detect format from extension             │  │
│  │    ├── FaultHandler ─── retry loop, abort detection              │  │
│  │    ├── ProgressReporter background status on locale 0            │  │
│  │    ├── ShardedOutput ── output/shard-{localeId}/                 │  │
│  │    ├── ResultAggregator per-locale → global stats (.scm + .json) │  │
│  │    └── Checkpoint ───── resume after node failure                │  │
│  │                                                                   │  │
│  │  forall idx in dynamic(docPaths.domain, chunkSize) {             │  │
│  │    handle = ddac_init()                                          │  │
│  │    result = safeParse(handle, path, outPath, fmt)                │  │
│  │    accumulate(result)                                            │  │
│  │  }                                                               │  │
│  └────────────────────────────┬──────────────────────────────────────┘  │
│                               │ C FFI (by value, flat struct)           │
│  ┌────────────────────────────▼──────────────────────────────────────┐  │
│  │                    Zig FFI Dispatcher (zero overhead)              │  │
│  │                    ffi/zig/src/docudactyl_ffi.zig                 │  │
│  │                                                                   │  │
│  │  ddac_parse() ─── detect format ─── dispatch to C library:       │  │
│  │    ├── .pdf ──────→ Poppler (poppler-glib)                       │  │
│  │    ├── .jpg/.png ─→ Tesseract (libtesseract) + Leptonica        │  │
│  │    ├── .mp3/.wav ─→ FFmpeg (libavformat)                         │  │
│  │    ├── .mp4/.mkv ─→ FFmpeg (libavformat + libavcodec)            │  │
│  │    ├── .epub ─────→ libxml2                                      │  │
│  │    └── .shp/.tif ─→ GDAL                                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    Idris2 ABI Proofs (compile-time)                │  │
│  │                    src/abi/{Types,Layout,Foreign}.idr              │  │
│  │                                                                   │  │
│  │  ContentKind ── 7 variants, injective, decidably equal           │  │
│  │  ParseStatus ── 7 variants, retryable predicate                  │  │
│  │  ParseResult ── 952-byte struct, LP64 layout proof               │  │
│  │  ddac_parse_result_t ── C ABI compliant, cross-platform          │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌──────────────────────────────┐  ┌─────────────────────────────────┐ │
│  │  OCaml (offline, not HPC)    │  │  Ada TUI (standalone)           │ │
│  │  docudactyl-scm              │  │  docudactyl-tui                 │ │
│  │  JSON/text → S-expressions   │  │  Terminal document inspector    │ │
│  └──────────────────────────────┘  └─────────────────────────────────┘ │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Julia (legacy — replaced by Chapel HPC pipeline)                 │  │
│  │  src/julia/ — extraction, analysis, parallel, CLI                 │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

Data Flow:
  manifest.txt ──→ Chapel (distribute) ──→ Zig FFI ──→ C parsers
                                                           │
                                       output/shard-N/*.scm ◄──┘
                                       output/run-report.scm

Offline:
  output/*.json ──→ OCaml docudactyl-scm ──→ *.scm (S-expressions)
```

## Completion Dashboard

| Component              | Status      | Progress                     |
|------------------------|-------------|------------------------------|
| Chapel HPC Engine      | Complete    | `██████████` 100%            |
| Zig FFI Dispatcher     | Complete    | `██████████` 100%            |
| Idris2 ABI Proofs      | Complete    | `██████████` 100%            |
| C Header (interop)     | Complete    | `██████████` 100%            |
| OCaml Scheme Emitter   | Stable      | `██████████` 100%            |
| Ada TUI                | Stable      | `██████████` 100%            |
| Julia (legacy)         | Deprecated  | `██████████` 100% (frozen)   |
| Checkpoint & Resume    | Complete    | `██████████` 100%            |
| Integration Tests      | Complete    | `██████████` 100%            |
| Scale Testing          | Verified    | `██████████` 100%            |
| Multi-Locale Testing   | Not Started | `░░░░░░░░░░` 0%             |
| Error Path Testing     | Complete    | `██████████` 100%            |
| Cluster Deployment     | Complete    | `██████████` 100%            |
| Version Pinning        | Complete    | `██████████` 100%            |
| Deps Check             | Complete    | `██████████` 100%            |

**Overall: `█████████░` 90%** (multi-locale testing requires cluster access)

## Key Dependencies

| Dependency       | Version  | Purpose                        |
|------------------|----------|--------------------------------|
| Chapel           | 2.7.0    | HPC orchestration (N locales)  |
| Zig              | 0.15.2   | FFI wrapper, zero runtime cost |
| Idris2           | 0.8.0    | ABI formal proofs              |
| Poppler          | 25.07.0  | PDF text + metadata extraction |
| Tesseract        | 5.5.2    | OCR (image → text)             |
| Leptonica        | 1.87.0   | Image I/O for Tesseract        |
| FFmpeg           | 7.1.2    | Audio/video metadata           |
| libxml2          | 2.12.10  | EPUB/XHTML parsing             |
| GDAL             | 3.11.5   | Geospatial data extraction     |
| libvips          | 8.17.3   | Image metadata                 |
| OCaml            | 5.4.1    | Offline Scheme transformer     |
| Ada/GNAT         | —        | TUI (terminal inspector)       |

## Scale Targets

| Metric         | Local Test (verified) | Cluster Target       |
|----------------|----------------------|----------------------|
| Documents      | 2,105                | 170,000,000          |
| Locales        | 1                    | 64–512               |
| Throughput     | 19.35 docs/s         | ~1,200–10,000 docs/s |
| Failure rate   | 0.0%                 | < 5.0%               |
| Output size    | ~1 MB                | ~1.7 TB              |
| Memory/locale  | ~100 MB              | ~4–8 GB              |
