# Docudactyl ABI/FFI Documentation

## Overview

This library follows the **Hyperpolymath RSR Standard** for ABI and FFI design:

- **ABI (Application Binary Interface)** defined in **Idris2** with formal proofs
- **FFI (Foreign Function Interface)** implemented in **Zig** for C compatibility
- **Generated C headers** bridge Idris2 ABI to Zig FFI
- **Chapel HPC** calls through standard C ABI for distributed execution

## Architecture

```
┌─────────────────────────────────────────────┐
│  ABI Definitions (Idris2)                   │
│  src/Docudactyl/ABI/                        │
│  - Types.idr      (14 types with proofs)    │
│  - Layout.idr     (5 struct layout proofs)  │
│  - Foreign.idr    (51 FFI declarations)     │
└─────────────────┬───────────────────────────┘
                  │
                  │ generates (via Justfile recipe)
                  ▼
┌─────────────────────────────────────────────┐
│  C Headers (auto-generated)                 │
│  generated/abi/docudactyl_ffi.h             │
└─────────────────┬───────────────────────────┘
                  │
                  │ imported by
                  ▼
┌─────────────────────────────────────────────┐
│  FFI Implementation (Zig)                   │
│  ffi/zig/src/docudactyl_ffi.zig + 9 modules│
│  - 10 submodules (stages, capnp, cache,     │
│    dragonfly, prefetch, conduit, gpu_ocr,   │
│    hw_crypto, ml_inference)                 │
│  - Links: Poppler, Tesseract, FFmpeg,       │
│    libxml2, GDAL, libvips, LMDB            │
│  - dlopen: ONNX Runtime, PaddleOCR, CUDA   │
└─────────────────┬───────────────────────────┘
                  │
                  │ compiled to libdocudactyl_ffi.so
                  ▼
┌─────────────────────────────────────────────┐
│  Chapel HPC Engine via C ABI                │
│  src/chapel/FFIBridge.chpl                  │
│  - 51 extern proc declarations             │
│  - Distributed across 64-512 locales       │
└─────────────────────────────────────────────┘
```

## Directory Structure

```
docudactyl/
├── src/
│   └── Docudactyl/
│       └── ABI/                  # ABI definitions (Idris2)
│           ├── Types.idr         # 14 types: ContentKind, ParseStatus, MlStatus,
│           │                     #   MlStage, ExecProvider, Sha256Tier, etc.
│           ├── Layout.idr        # Struct layout proofs: ParseResult (952B),
│           │                     #   MlResult (48B), CryptoCaps (16B)
│           └── Foreign.idr       # 51 FFI declarations matching C header
│
├── ffi/
│   └── zig/                      # FFI implementation (Zig)
│       ├── build.zig             # Build config (links 7 C libraries)
│       ├── src/
│       │   ├── docudactyl_ffi.zig    # Core: init, free, parse, version
│       │   ├── stages.zig            # 20 processing stages
│       │   ├── capnp.zig             # Cap'n Proto serialisation
│       │   ├── cache.zig             # LMDB L1 cache
│       │   ├── dragonfly.zig         # Dragonfly L2 cache
│       │   ├── prefetch.zig          # io_uring I/O prefetcher
│       │   ├── conduit.zig           # Magic-byte detection + validation
│       │   ├── gpu_ocr.zig           # GPU OCR (PaddleOCR/Tesseract CUDA)
│       │   ├── hw_crypto.zig         # Hardware SHA-256 acceleration
│       │   └── ml_inference.zig      # ONNX Runtime ML engine
│       └── test/
│           └── integration_test.zig  # 40+ C ABI compliance tests
│
├── generated/                    # Auto-generated files
│   └── abi/
│       └── docudactyl_ffi.h      # Generated from Zig FFI exports
│
└── docudactyl.ipkg               # Idris2 package (3 modules)
```

## Proven Types (Idris2)

The ABI layer formally proves:

| Type | Variants | Proof |
|------|----------|-------|
| `ContentKind` | 7 (PDF, Image, Audio, Video, EPUB, GeoSpatial, Unknown) | Enum injectivity |
| `ParseStatus` | 6 (Ok, Error, FileNotFound, ParseError, UnsupportedFormat, OutOfMemory) | Enum injectivity |
| `MlStatus` | 5 (Ok, ModelNotFound, InferenceError, InputError, OnnxNotAvailable) | Enum injectivity |
| `MlStage` | 5 (NER, Whisper, ImageClassify, Layout, Handwriting) | Enum injectivity |
| `ExecProvider` | 4 (TensorRT, CUDA, OpenVINO, CPU) | Enum injectivity |
| `Sha256Tier` | 3 (Dedicated, Avx2Buffer, Software) | Enum injectivity |
| `OcrStatus` | 4 | Enum injectivity |
| `GpuBackend` | 3 | Enum injectivity |
| `ConduitValidation` | 4 | Enum injectivity |

### Struct Layout Proofs

| Struct | Size | Alignment | Proof |
|--------|------|-----------|-------|
| `ParseResult` | 952 bytes | 8-byte (LP64) | `Divides 8 952 = MkDivides 119` |
| `MlResult` | 48 bytes | 8-byte | `Divides 8 48 = MkDivides 6` |
| `CryptoCaps` | 16 bytes | 1-byte | Field offset chain |
| `OcrResult` | 48 bytes | — | Size assertion |
| `ConduitResult` | 88 bytes | — | Size assertion |

## Building

### Build FFI Library

```bash
just build-ffi                    # Build via Justfile
# or directly:
cd ffi/zig && zig build -Doptimize=ReleaseFast
```

### Verify Idris2 ABI Proofs

```bash
just build-idris
# or directly:
idris2 --build docudactyl.ipkg
```

### Generate C Header

```bash
just generate-abi-header
```

### Run Tests

```bash
just test-ffi     # 40+ integration tests against C ABI
just test-idris   # Verify Idris2 proofs compile
```

## C API Summary

All 51 functions use the `ddac_` prefix:

| Category | Functions |
|----------|-----------|
| **Core lifecycle** | `ddac_init`, `ddac_free`, `ddac_parse`, `ddac_version` |
| **Handle setters** | `ddac_set_ml_handle`, `ddac_set_gpu_ocr_handle` |
| **LMDB cache** | `ddac_cache_init`, `ddac_cache_free`, `ddac_cache_lookup`, `ddac_cache_store`, `ddac_cache_count`, `ddac_cache_sync` |
| **Dragonfly** | `ddac_dragonfly_connect`, `ddac_dragonfly_close`, `ddac_dragonfly_lookup`, `ddac_dragonfly_store`, `ddac_dragonfly_count` |
| **I/O prefetcher** | `ddac_prefetch_init`, `ddac_prefetch_hint`, `ddac_prefetch_done`, `ddac_prefetch_free`, `ddac_prefetch_inflight` |
| **ML inference** | `ddac_ml_init`, `ddac_ml_free`, `ddac_ml_available`, `ddac_ml_provider`, `ddac_ml_provider_name`, `ddac_ml_set_model_dir`, `ddac_ml_run_stage`, `ddac_ml_stats`, `ddac_ml_result_size`, `ddac_ml_stage_count`, `ddac_ml_model_name` |
| **GPU OCR** | `ddac_gpu_ocr_init`, `ddac_gpu_ocr_free`, `ddac_gpu_ocr_backend`, `ddac_gpu_ocr_submit`, `ddac_gpu_ocr_flush`, `ddac_gpu_ocr_results_ready`, `ddac_gpu_ocr_collect`, `ddac_gpu_ocr_stats`, `ddac_gpu_ocr_max_batch`, `ddac_gpu_ocr_result_size` |
| **Hardware crypto** | `ddac_crypto_detect`, `ddac_crypto_sha256_tier`, `ddac_crypto_sha256_name`, `ddac_crypto_batch_sha256`, `ddac_crypto_caps_size` |
| **Conduit** | `ddac_conduit_process`, `ddac_conduit_batch`, `ddac_conduit_result_size` |

## Usage from Chapel

```chapel
extern proc ddac_init(): c_ptr(void);
extern proc ddac_free(handle: c_ptr(void)): void;
extern proc ddac_parse(handle: c_ptr(void), inputPath: c_ptrConst(c_char),
                       outputPath: c_ptrConst(c_char),
                       outputFormat: c_ptrConst(c_char)): ddac_parse_result_t;

// In forall loop:
var handle = ddac_init();
defer ddac_free(handle);
var result = ddac_parse(handle, path.c_str(), outPath.c_str(), "scheme".c_str());
```

## Contributing

When modifying the ABI/FFI:

1. **Update Idris2 ABI first** (`src/Docudactyl/ABI/*.idr`)
   - Add/modify type definitions with proofs
   - Update struct layout proofs
   - Add FFI declarations
2. **Update Zig FFI** (`ffi/zig/src/`)
   - Implement new functions matching C ABI
   - Ensure `comptime` assertions match Idris2 proofs
3. **Regenerate C header** (`just generate-abi-header`)
4. **Add integration tests** (`ffi/zig/test/integration_test.zig`)
5. **Update Chapel extern declarations** (`src/chapel/FFIBridge.chpl`)

## License

SPDX-License-Identifier: PMPL-1.0-or-later

## See Also

- [Idris2 Documentation](https://idris2.readthedocs.io)
- [Zig Documentation](https://ziglang.org/documentation/master/)
- [Chapel Documentation](https://chapel-lang.org/docs/)
- [Rhodium Standard Repositories](https://github.com/hyperpolymath/rhodium-standard-repositories)
