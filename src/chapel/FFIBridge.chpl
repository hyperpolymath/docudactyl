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
  require "../../ffi/zig/include/docudactyl_ffi.h";

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

  /** Parse a single document.
      - handle: from ddac_init()
      - input_path: absolute path to source document
      - output_path: absolute path for extracted content
      - output_fmt: 0=scheme, 1=json, 2=csv
      Returns a flat result struct (by value, no allocation). */
  extern proc ddac_parse(
    handle: c_ptr(void),
    input_path: c_ptrConst(c_char),
    output_path: c_ptrConst(c_char),
    output_fmt: c_int
  ): ddac_parse_result_t;

  // ── Version information ───────────────────────────────────────────────

  /** Get library version string (static storage, do not free). */
  extern proc ddac_version(): c_ptrConst(c_char);

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
