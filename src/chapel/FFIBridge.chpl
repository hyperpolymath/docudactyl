// Docudactyl HPC — FFI Bridge to Zig/C Libraries
//
// Extern declarations matching ffi/zig/src/docudactyl_ffi.zig.
// Chapel calls these to dispatch document parsing to native C parsers.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module FFIBridge {
  use CTypes;

  // Pull in the C header so Chapel knows the struct layout
  require "../../generated/abi/docudactyl_ffi.h";

  // ── Result struct ─────────────────────────────────────────────────────
  // Must match ddac_parse_result_t in docudactyl_ffi.h / docudactyl_ffi.zig.
  // All fixed-size fields, no heap pointers.

  extern record ddac_parse_result_t {
    var status: c_int;               // 0 = success, nonzero = error
    var content_kind: c_int;         // ContentKind enum value
    var page_count: int(32);         // pages (PDF/EPUB) or 0
    var word_count: int(64);         // extracted words
    var char_count: int(64);         // extracted characters
    var duration_sec: real(64);      // audio/video duration (seconds)
    var parse_time_ms: real(64);     // wall-clock parse time (ms)
    var sha256: c_array(c_char, 65);       // hex SHA-256 + null
    var error_msg: c_array(c_char, 256);   // error message + null
    var title: c_array(c_char, 256);       // document title
    var author: c_array(c_char, 256);      // document author
    var mime_type: c_array(c_char, 64);    // detected MIME type
  }

  // ── Library lifecycle ─────────────────────────────────────────────────

  /** Initialise library contexts (Tesseract, GDAL, vips).
      Returns opaque handle; one per Chapel task. */
  extern proc ddac_init(): c_ptr(void);

  /** Free library contexts. Safe to call with nil. */
  extern proc ddac_free(handle: c_ptr(void)): void;

  // ── Core parse operation ──────────────────────────────────────────────

  /** Parse a single document with optional processing stages.
      - handle: from ddac_init()
      - input_path: absolute path to source document
      - output_path: absolute path for extracted content
      - output_fmt: 0=scheme, 1=json, 2=csv
      - stage_flags: bitmask of DDAC_STAGE_* flags (0 = base parse only)
      Returns a flat result struct (by value, no allocation).
      Stage results written to {output_path}.stages if stage_flags != 0. */
  extern proc ddac_parse(
    handle: c_ptr(void),
    input_path: c_ptrConst(c_char),
    output_path: c_ptrConst(c_char),
    output_fmt: c_int,
    stage_flags: uint(64)
  ): ddac_parse_result_t;

  // ── Version information ───────────────────────────────────────────────

  /** Get library version string (static storage, do not free). */
  extern proc ddac_version(): c_ptrConst(c_char);

  // ── LMDB Result Cache ────────────────────────────────────────────────

  /** Initialise LMDB cache at dir_path. Returns opaque handle or nil. */
  extern proc ddac_cache_init(
    dir_path: c_ptrConst(c_char),
    max_size_mb: uint(64)
  ): c_ptr(void);

  /** Free LMDB cache. Safe to call with nil. */
  extern proc ddac_cache_free(cache: c_ptr(void)): void;

  /** Look up a cached result.
      Returns 1 (hit) or 0 (miss). On hit, result_out is populated. */
  extern proc ddac_cache_lookup(
    cache: c_ptr(void),
    doc_path: c_ptrConst(c_char),
    mtime: int(64),
    file_size: int(64),
    result_out: c_ptr(void),
    result_size: c_size_t
  ): c_int;

  /** Store a parse result in the cache. */
  extern proc ddac_cache_store(
    cache: c_ptr(void),
    doc_path: c_ptrConst(c_char),
    mtime: int(64),
    file_size: int(64),
    result: c_ptrConst(void),
    result_size: c_size_t
  ): void;

  /** Return number of entries in the cache. */
  extern proc ddac_cache_count(cache: c_ptr(void)): uint(64);

  /** Sync cache to disk. */
  extern proc ddac_cache_sync(cache: c_ptr(void)): void;

  // ── Helpers ───────────────────────────────────────────────────────────

  /** Extract a Chapel string from a fixed-size c_char array. */
  proc fixedArrayToString(const ref arr: c_array(c_char, ?N)): string {
    var result: string;
    for i in 0..#N {
      if arr[i] == 0 then break;
      result += chr(arr[i]: int);
    }
    return result;
  }

  /** Check if a parse result indicates success. */
  proc parseSucceeded(const ref r: ddac_parse_result_t): bool {
    return r.status == 0;
  }

  /** Get human-readable error from a parse result. */
  proc parseErrorMsg(const ref r: ddac_parse_result_t): string {
    if r.status == 0 then return "";
    return fixedArrayToString(r.error_msg);
  }
}
