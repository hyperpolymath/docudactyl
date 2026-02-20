/**
 * Docudactyl FFI -- C ABI Header
 *
 * AUTO-GENERATED from Idris2 ABI definitions.
 * DO NOT EDIT MANUALLY -- regenerate with: just generate-abi-header
 *
 * Source: src/Docudactyl/ABI/Types.idr, Layout.idr, Foreign.idr
 * Struct size: 952 bytes (proven in Layout.idr)
 *
 * SPDX-License-Identifier: PMPL-1.0-or-later
 * Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
 */

#ifndef DOCUDACTYL_FFI_H
#define DOCUDACTYL_FFI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Content Kind (proven exhaustive and injective: Types.idr) */
enum ddac_content_kind {
    DDAC_PDF = 0,
    DDAC_IMAGE = 1,
    DDAC_AUDIO = 2,
    DDAC_VIDEO = 3,
    DDAC_EPUB = 4,
    DDAC_GEO_SPATIAL = 5,
    DDAC_UNKNOWN = 6
};

/* Parse Status (retryable: Error, OutOfMemory -- see Types.idr) */
enum ddac_parse_status {
    DDAC_OK = 0,
    DDAC_ERROR = 1,
    DDAC_FILE_NOT_FOUND = 2,
    DDAC_PARSE_ERROR = 3,
    DDAC_NULL_POINTER = 4,
    DDAC_UNSUPPORTED_FORMAT = 5,
    DDAC_OUT_OF_MEMORY = 6
};

/* ═══════════════════════════════════════════════════════════════════════
 * Processing Stage Bitmask Constants
 *
 * Pass a combination of these flags as the stage_flags parameter to
 * ddac_parse() to enable per-document analysis stages.
 * Stage results are written to {output_path}.stages.capnp in Cap'n Proto
 * binary format.  Decode with:
 *   capnp decode schema/stages.capnp StageResults < result.stages.capnp
 * ═══════════════════════════════════════════════════════════════════════ */

/* Text analysis stages */
#define DDAC_STAGE_NONE              UINT64_C(0)
#define DDAC_STAGE_LANGUAGE_DETECT   (UINT64_C(1) << 0)
#define DDAC_STAGE_READABILITY       (UINT64_C(1) << 1)
#define DDAC_STAGE_KEYWORDS          (UINT64_C(1) << 2)
#define DDAC_STAGE_CITATION_EXTRACT  (UINT64_C(1) << 3)

/* Image/OCR stages */
#define DDAC_STAGE_OCR_CONFIDENCE    (UINT64_C(1) << 4)
#define DDAC_STAGE_PERCEPTUAL_HASH   (UINT64_C(1) << 5)

/* Document structure stages */
#define DDAC_STAGE_TOC_EXTRACT       (UINT64_C(1) << 6)
#define DDAC_STAGE_MULTI_LANG_OCR    (UINT64_C(1) << 7)

/* Audio/Video stages */
#define DDAC_STAGE_SUBTITLE_EXTRACT  (UINT64_C(1) << 8)

/* Preservation/Integrity stages */
#define DDAC_STAGE_PREMIS_METADATA   (UINT64_C(1) << 9)
#define DDAC_STAGE_MERKLE_PROOF      (UINT64_C(1) << 10)
#define DDAC_STAGE_EXACT_DEDUP       (UINT64_C(1) << 11)
#define DDAC_STAGE_NEAR_DEDUP        (UINT64_C(1) << 12)
#define DDAC_STAGE_COORD_NORMALIZE   (UINT64_C(1) << 13)

/* ML-dependent stages (stub implementations) */
#define DDAC_STAGE_NER               (UINT64_C(1) << 14)
#define DDAC_STAGE_WHISPER           (UINT64_C(1) << 15)
#define DDAC_STAGE_IMAGE_CLASSIFY    (UINT64_C(1) << 16)
#define DDAC_STAGE_LAYOUT_ANALYSIS   (UINT64_C(1) << 17)
#define DDAC_STAGE_HANDWRITING_OCR   (UINT64_C(1) << 18)
#define DDAC_STAGE_FORMAT_CONVERT    (UINT64_C(1) << 19)

/* Presets */
#define DDAC_STAGE_ALL               ((UINT64_C(1) << 20) - 1)
#define DDAC_STAGE_FAST              (DDAC_STAGE_LANGUAGE_DETECT | \
                                      DDAC_STAGE_READABILITY | \
                                      DDAC_STAGE_KEYWORDS | \
                                      DDAC_STAGE_EXACT_DEDUP | \
                                      DDAC_STAGE_PREMIS_METADATA | \
                                      DDAC_STAGE_MERKLE_PROOF | \
                                      DDAC_STAGE_CITATION_EXTRACT)
#define DDAC_STAGE_ANALYSIS          (DDAC_STAGE_FAST | \
                                      DDAC_STAGE_OCR_CONFIDENCE | \
                                      DDAC_STAGE_PERCEPTUAL_HASH | \
                                      DDAC_STAGE_TOC_EXTRACT | \
                                      DDAC_STAGE_NEAR_DEDUP | \
                                      DDAC_STAGE_COORD_NORMALIZE | \
                                      DDAC_STAGE_SUBTITLE_EXTRACT)

/* Parse Result -- 952 bytes, 8-byte aligned (Layout.idr) */
typedef struct ddac_parse_result_t {
    int32_t  status;
    int32_t  content_kind;
    int32_t  page_count;
    int32_t  _pad0;
    int64_t  word_count;
    int64_t  char_count;
    double   duration_sec;
    double   parse_time_ms;
    char     sha256[65];
    char     _pad1[7];
    char     error_msg[256];
    char     title[256];
    char     author[256];
    char     mime_type[64];
} ddac_parse_result_t;

_Static_assert(sizeof(ddac_parse_result_t) == 952,
    "ddac_parse_result_t must be 952 bytes (Idris2 proof: Layout.idr)");
_Static_assert(_Alignof(ddac_parse_result_t) == 8,
    "ddac_parse_result_t must be 8-byte aligned (Idris2 proof: Layout.idr)");

/* ═══════════════════════════════════════════════════════════════════════
 * Library Lifecycle
 * ═══════════════════════════════════════════════════════════════════════ */

void *ddac_init(void);
void  ddac_free(void *handle);
ddac_parse_result_t ddac_parse(void *handle, const char *input_path,
                               const char *output_path, int output_fmt,
                               uint64_t stage_flags);
const char *ddac_version(void);

/* ═══════════════════════════════════════════════════════════════════════
 * LMDB Result Cache
 *
 * Zero-copy reads, ACID, multi-reader/single-writer.
 * Each Chapel locale should have its own cache directory.
 * ═══════════════════════════════════════════════════════════════════════ */

void    *ddac_cache_init(const char *dir_path, uint64_t max_size_mb);
void     ddac_cache_free(void *cache);
int      ddac_cache_lookup(void *cache, const char *doc_path,
                           int64_t mtime, int64_t file_size,
                           void *result_out, size_t result_size);
void     ddac_cache_store(void *cache, const char *doc_path,
                          int64_t mtime, int64_t file_size,
                          const void *result, size_t result_size);
uint64_t ddac_cache_count(void *cache);
void     ddac_cache_sync(void *cache);

/* ═══════════════════════════════════════════════════════════════════════
 * I/O Prefetcher (Linux io_uring + fadvise)
 *
 * Prefetches upcoming documents into page cache while current one parses.
 * Uses io_uring on Linux 5.6+, falls back to posix_fadvise.
 * ═══════════════════════════════════════════════════════════════════════ */

void    *ddac_prefetch_init(uint32_t window_size);
void     ddac_prefetch_hint(void *handle, const char *path);
void     ddac_prefetch_done(void *handle, const char *path);
void     ddac_prefetch_free(void *handle);
uint32_t ddac_prefetch_inflight(void *handle);

/* ═══════════════════════════════════════════════════════════════════════
 * Dragonfly / Redis L2 Cache (RESP2 protocol)
 *
 * Cross-locale shared cache via Dragonfly (Redis-compatible, 25x faster).
 * Cache key: "ddac:{sha256_hex}"  Value: raw ddac_parse_result_t bytes.
 * Multiple Chapel locales can share a single Dragonfly instance.
 * ═══════════════════════════════════════════════════════════════════════ */

void    *ddac_dragonfly_connect(const char *host_port);
void     ddac_dragonfly_close(void *handle);
int      ddac_dragonfly_lookup(void *handle, const char *sha256,
                                void *result_out, size_t result_size);
void     ddac_dragonfly_store(void *handle, const char *sha256,
                               const void *result, size_t result_size,
                               uint32_t ttl_secs);
uint64_t ddac_dragonfly_count(void *handle);

/* ═══════════════════════════════════════════════════════════════════════
 * ML Inference Engine (ONNX Runtime)
 *
 * Unified ML backend for all ML-dependent processing stages.
 * Uses ONNX Runtime (dlopen, no link-time dependency).
 * Auto-selects: TensorRT > CUDA > OpenVINO > CPU
 *
 * Stages:  0=NER, 1=Whisper, 2=ImageClassify, 3=Layout, 4=Handwriting
 * Models:  Place {stage}.onnx in the model directory.
 * ═══════════════════════════════════════════════════════════════════════ */

/* ML execution providers */
#define DDAC_ML_TENSORRT   0
#define DDAC_ML_CUDA       1
#define DDAC_ML_OPENVINO   2
#define DDAC_ML_CPU        3

/* ML inference result — 56 bytes, 8-byte aligned */
typedef struct ddac_ml_result_t {
    uint8_t  status;           /* 0=ok, 1=model_missing, 2=inference_err, 3=input_err, 4=no_onnx */
    uint8_t  stage;            /* MlStage enum */
    uint8_t  provider;         /* ExecProvider enum */
    uint8_t  _pad[5];
    int64_t  inference_time_us;
    int64_t  output_count;     /* entities/tokens/labels */
    double   confidence;       /* 0.0-1.0, -1.0 if N/A */
    int64_t  text_offset;
    int64_t  text_length;
} ddac_ml_result_t;

_Static_assert(sizeof(ddac_ml_result_t) == 48,
    "ddac_ml_result_t must be 48 bytes");
_Static_assert(_Alignof(ddac_ml_result_t) == 8,
    "ddac_ml_result_t must be 8-byte aligned");

void        *ddac_ml_init(void);
void         ddac_ml_free(void *handle);
uint8_t      ddac_ml_available(void *handle);
uint8_t      ddac_ml_provider(void *handle);
const char  *ddac_ml_provider_name(void *handle);
void         ddac_ml_set_model_dir(void *handle, const char *dir);
int          ddac_ml_run_stage(void *handle, uint8_t stage,
                                const char *input_path,
                                ddac_ml_result_t *result_out);
void         ddac_ml_stats(void *handle, uint64_t *total_inferences,
                            uint64_t *total_inference_us);
size_t       ddac_ml_result_size(void);
uint8_t      ddac_ml_stage_count(void);
const char  *ddac_ml_model_name(uint8_t stage);

/* ═══════════════════════════════════════════════════════════════════════
 * Hardware Crypto Acceleration
 *
 * Detects and reports CPU crypto capabilities for SHA-256 hashing.
 * Zig's std SHA-256 auto-uses SHA-NI/ARM-SHA2 for single-file hashing.
 * The batch API provides multi-buffer hashing (4 files at once via AVX2).
 *
 * Tiers: 0=SHA-NI/ARM-SHA2, 1=AVX2 multi-buffer, 2=software
 * ═══════════════════════════════════════════════════════════════════════ */

/* Crypto capabilities — 16 bytes */
typedef struct ddac_crypto_caps_t {
    uint8_t  has_sha_ni;       /* x86-64 SHA-NI instructions */
    uint8_t  has_avx2;         /* x86-64 AVX2 (multi-buffer) */
    uint8_t  has_avx512;       /* x86-64 AVX-512F */
    uint8_t  has_arm_sha2;     /* AArch64 SHA2 extension */
    uint8_t  has_arm_sha512;   /* AArch64 SHA-512 extension */
    uint8_t  has_aes_ni;       /* x86-64 AES-NI */
    uint8_t  _pad[2];
    uint8_t  sha256_tier;      /* 0=dedicated, 1=AVX2, 2=software */
    uint8_t  _pad2[7];
} ddac_crypto_caps_t;

_Static_assert(sizeof(ddac_crypto_caps_t) == 16,
    "ddac_crypto_caps_t must be 16 bytes");

void        ddac_crypto_detect(ddac_crypto_caps_t *caps_out);
uint8_t     ddac_crypto_sha256_tier(void);
const char *ddac_crypto_sha256_name(void);
uint32_t    ddac_crypto_batch_sha256(const char **paths,
                                      char (*hex_out)[65],
                                      uint32_t count);
size_t      ddac_crypto_caps_size(void);

/* ═══════════════════════════════════════════════════════════════════════
 * GPU-Accelerated OCR Coprocessor
 *
 * Batched OCR using GPU acceleration when available:
 *   Priority: PaddleOCR (CUDA/TensorRT) > Tesseract CUDA > Tesseract CPU
 * Submit images to a queue, flush to batch-process on GPU, then collect
 * results.  When no GPU is detected, results signal status=3 (gpu_error)
 * indicating the caller should fall back to the standard CPU parse path.
 * ═══════════════════════════════════════════════════════════════════════ */

/* GPU backend detection result */
#define DDAC_GPU_PADDLE     0
#define DDAC_GPU_TESS_CUDA  1
#define DDAC_GPU_CPU_ONLY   2

/* OCR result — 48 bytes, 8-byte aligned */
typedef struct ddac_ocr_result_t {
    uint8_t  status;         /* 0=success, 1=error, 2=skipped, 3=gpu_error */
    int8_t   confidence;     /* OCR confidence 0-100, -1 if unavailable */
    uint8_t  _pad[6];
    int64_t  char_count;     /* characters extracted */
    int64_t  word_count;     /* words extracted */
    int64_t  gpu_time_us;    /* GPU processing time (microseconds) */
    int64_t  text_offset;    /* offset into shared text buffer */
    int64_t  text_length;    /* length of extracted text */
} ddac_ocr_result_t;

_Static_assert(sizeof(ddac_ocr_result_t) == 48,
    "ddac_ocr_result_t must be 48 bytes");
_Static_assert(_Alignof(ddac_ocr_result_t) == 8,
    "ddac_ocr_result_t must be 8-byte aligned");

void    *ddac_gpu_ocr_init(void);
void     ddac_gpu_ocr_free(void *handle);
uint8_t  ddac_gpu_ocr_backend(void *handle);
int      ddac_gpu_ocr_submit(void *handle, const char *image_path,
                              const char *output_path);
void     ddac_gpu_ocr_flush(void *handle);
uint32_t ddac_gpu_ocr_results_ready(void *handle);
int      ddac_gpu_ocr_collect(void *handle, uint32_t slot_id,
                               ddac_ocr_result_t *result_out);
void     ddac_gpu_ocr_stats(void *handle, uint64_t *submitted,
                              uint64_t *completed, uint64_t *batches,
                              uint64_t *gpu_time_us);
uint32_t ddac_gpu_ocr_max_batch(void);
size_t   ddac_gpu_ocr_result_size(void);

/* ═══════════════════════════════════════════════════════════════════════
 * Preprocessing Conduit
 *
 * Lightweight pre-processing pipeline that runs before the main parse.
 * Pre-computes metadata that would otherwise be computed redundantly:
 *   - Content-type detection via magic bytes (not just extension)
 *   - File validation (empty, corrupt, accessible)
 *   - SHA-256 pre-computation (feeds L2 Dragonfly cache lookup)
 *   - File size capture (avoids stat() in main loop)
 *
 * Run ddac_conduit_batch() on a block of paths before entering the
 * forall loop to amortise I/O latency and pre-populate cache keys.
 * ═══════════════════════════════════════════════════════════════════════ */

/* Conduit validation codes */
#define DDAC_CONDUIT_OK          0
#define DDAC_CONDUIT_NOT_FOUND   1
#define DDAC_CONDUIT_EMPTY       2
#define DDAC_CONDUIT_UNREADABLE  3

/* Conduit result — 88 bytes, 8-byte aligned */
typedef struct ddac_conduit_result_t {
    uint8_t  content_kind;     /* ContentKind (0-6) from magic bytes */
    uint8_t  validation;       /* 0=ok, 1=not_found, 2=empty, 3=unreadable */
    uint8_t  _pad[6];         /* alignment padding */
    int64_t  file_size;       /* file size in bytes */
    char     sha256[65];      /* hex SHA-256 + null */
    char     _pad2[7];        /* alignment padding */
} ddac_conduit_result_t;

_Static_assert(sizeof(ddac_conduit_result_t) == 88,
    "ddac_conduit_result_t must be 88 bytes");
_Static_assert(_Alignof(ddac_conduit_result_t) == 8,
    "ddac_conduit_result_t must be 8-byte aligned");

/** Pre-process a single file: detect type, validate, compute SHA-256.
 *  Returns 0 on success, non-zero on validation failure. */
int      ddac_conduit_process(const char *path,
                               ddac_conduit_result_t *result_out);

/** Batch pre-process N files. Returns number of valid files. */
uint32_t ddac_conduit_batch(const char **paths,
                             ddac_conduit_result_t *results,
                             uint32_t count);

/** Get sizeof(ddac_conduit_result_t) for Chapel allocation. */
size_t   ddac_conduit_result_size(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCUDACTYL_FFI_H */
