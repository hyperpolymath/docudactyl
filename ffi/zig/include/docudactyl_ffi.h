/* Docudactyl FFI — C Header
 *
 * Declares the types and functions exported by libdocudactyl_ffi.
 * Used by Chapel's extern declarations.
 *
 * SPDX-License-Identifier: PMPL-1.0-or-later
 * Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
 */

#ifndef DOCUDACTYL_FFI_H
#define DOCUDACTYL_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Parse result — flat struct, no pointers, safe for FFI.
 * Must match the extern struct in docudactyl_ffi.zig exactly. */
typedef struct {
    int32_t status;            /* 0 = success, nonzero = error code */
    int32_t content_kind;      /* ContentKind enum value (0-6) */
    int32_t page_count;        /* pages (PDF/EPUB) or 0 */
    int32_t _pad0;             /* padding for 8-byte alignment */
    int64_t word_count;        /* extracted words */
    int64_t char_count;        /* extracted characters */
    double  duration_sec;      /* audio/video duration in seconds */
    double  parse_time_ms;     /* wall-clock parse time in ms */
    char    sha256[65];        /* hex SHA-256 + null terminator */
    char    error_msg[256];    /* error message + null terminator */
    char    title[256];        /* document title */
    char    author[256];       /* document author */
    char    mime_type[64];     /* detected MIME type */
} ddac_parse_result_t;

/* Library lifecycle */
void* ddac_init(void);
void  ddac_free(void* handle);

/* Core parse operation */
ddac_parse_result_t ddac_parse(
    void*       handle,
    const char* input_path,
    const char* output_path,
    int32_t     output_fmt
);

/* Version string (static storage, do not free) */
const char* ddac_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCUDACTYL_FFI_H */
