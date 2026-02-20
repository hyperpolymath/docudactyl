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
 * Stage results are written to {output_path}.stages in JSON format.
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

#ifdef __cplusplus
}
#endif

#endif /* DOCUDACTYL_FFI_H */
