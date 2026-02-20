/**
 * Docudactyl FFI — C ABI Header
 *
 * AUTO-GENERATED from Idris2 ABI definitions (src/Docudactyl/ABI/Types.idr).
 * DO NOT EDIT MANUALLY — regenerate with: just generate-abi-header
 *
 * This header defines the C-compatible interface between Chapel (caller)
 * and the Zig FFI dispatcher (implementation). The struct layout is
 * formally verified by Idris2 proofs in src/Docudactyl/ABI/Layout.idr.
 *
 * SPDX-License-Identifier: PMPL-1.0-or-later
 * Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
 */

#ifndef DOCUDACTYL_FFI_H
#define DOCUDACTYL_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Content Kind ─────────────────────────────────────────────────────────── */
/* Proven exhaustive and injective by Idris2 (Types.idr:contentKindInjective) */

enum ddac_content_kind {
    DDAC_PDF        = 0,
    DDAC_IMAGE      = 1,
    DDAC_AUDIO      = 2,
    DDAC_VIDEO      = 3,
    DDAC_EPUB       = 4,
    DDAC_GEOSPATIAL = 5,
    DDAC_UNKNOWN    = 6
};

/* ── Parse Status ─────────────────────────────────────────────────────────── */
/* Maps to ParseStatus in Types.idr. Retryable: Error, OutOfMemory.          */

enum ddac_parse_status {
    DDAC_OK                = 0,
    DDAC_ERROR             = 1,
    DDAC_FILE_NOT_FOUND    = 2,
    DDAC_PARSE_ERROR       = 3,
    DDAC_NULL_POINTER      = 4,
    DDAC_UNSUPPORTED_FORMAT = 5,
    DDAC_OUT_OF_MEMORY     = 6
};

/* ── Parse Result ─────────────────────────────────────────────────────────── */
/* 952 bytes, 8-byte aligned (LP64). Layout proven in Layout.idr.            */
/*                                                                            */
/* Offset  Size  Field                                                        */
/* ------  ----  -----                                                        */
/*   0       4   status (ddac_parse_status)                                   */
/*   4       4   content_kind (ddac_content_kind)                             */
/*   8       4   page_count                                                   */
/*  12       4   (padding for int64 alignment)                                */
/*  16       8   word_count                                                   */
/*  24       8   char_count                                                   */
/*  32       8   duration_sec                                                 */
/*  40       8   parse_time_ms                                                */
/*  48      65   sha256 (NUL-terminated)                                      */
/* 113       7   (padding)                                                    */
/* 120     256   error_msg (NUL-terminated)                                   */
/* 376     256   title (NUL-terminated)                                       */
/* 632     256   author (NUL-terminated)                                      */
/* 888      64   mime_type (NUL-terminated)                                   */
/* ------  ----                                                               */
/* Total: 952 bytes = 119 * 8 (Divides 8 952, proven: Layout.idr)            */

typedef struct ddac_parse_result_t {
    int32_t  status;           /* ddac_parse_status */
    int32_t  content_kind;     /* ddac_content_kind */
    int32_t  page_count;       /* pages (PDF/EPUB) or 0 */
    int32_t  _pad0;            /* alignment padding */
    int64_t  word_count;       /* extracted words */
    int64_t  char_count;       /* extracted characters */
    double   duration_sec;     /* audio/video duration, 0.0 for text */
    double   parse_time_ms;    /* wall-clock parse time in milliseconds */
    char     sha256[65];       /* hex-encoded SHA-256 of input file */
    char     _pad1[7];         /* alignment padding */
    char     error_msg[256];   /* error description (NUL-terminated) */
    char     title[256];       /* document title (NUL-terminated) */
    char     author[256];      /* document author (NUL-terminated) */
    char     mime_type[64];    /* detected MIME type (NUL-terminated) */
} ddac_parse_result_t;

/* Compile-time layout verification */
_Static_assert(sizeof(ddac_parse_result_t) == 952,
    "ddac_parse_result_t must be 952 bytes (Idris2 proof: Layout.idr)");
_Static_assert(_Alignof(ddac_parse_result_t) == 8,
    "ddac_parse_result_t must be 8-byte aligned (Idris2 proof: Layout.idr)");

/* ── Library Lifecycle ────────────────────────────────────────────────────── */

/**
 * Initialise the Docudactyl FFI library.
 * Allocates Tesseract, GDAL, and libvips contexts.
 * Returns an opaque handle, or NULL on failure.
 * Thread-safe: each thread should call ddac_init() separately.
 *
 * Proven non-null on success (Foreign.idr:initNonNull).
 */
void *ddac_init(void);

/**
 * Release all resources held by a handle.
 * Safe to call with NULL (no-op).
 * Proven idempotent (Foreign.idr:freeIdempotent).
 */
void ddac_free(void *handle);

/**
 * Parse a document.
 * Detects content type from file extension, dispatches to the
 * appropriate C library (Poppler, Tesseract, FFmpeg, libxml2, GDAL).
 * Writes extracted content to output_path.
 * Returns a result struct (by value) with parse summary.
 *
 * @param handle      Opaque handle from ddac_init()
 * @param input_path  Absolute path to input document
 * @param output_path Absolute path for extracted content output
 * @param output_fmt  Output format: 0=scheme, 1=json, 2=csv
 * @return            Parse result (status, counts, metadata)
 */
ddac_parse_result_t ddac_parse(void *handle,
                               const char *input_path,
                               const char *output_path,
                               int output_fmt);

/**
 * Get the library version string.
 * Returns a static NUL-terminated string (do not free).
 */
const char *ddac_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCUDACTYL_FFI_H */
