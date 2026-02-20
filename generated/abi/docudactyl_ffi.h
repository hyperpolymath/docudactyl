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

void *ddac_init(void);
void  ddac_free(void *handle);
ddac_parse_result_t ddac_parse(void *handle, const char *input_path,
                               const char *output_path, int output_fmt);
const char *ddac_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCUDACTYL_FFI_H */
