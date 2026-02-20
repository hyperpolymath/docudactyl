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
      Stage results written to {output_path}.stages.capnp (Cap'n Proto binary)
      if stage_flags != 0.  See schema/stages.capnp for the wire format. */
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

  // ── Subsystem handle attachment ─────────────────────────────────────
  //
  // Attach ML and GPU OCR handles to a parse handle so that ddac_parse()
  // can dispatch to these subsystems internally. The handles remain owned
  // by Chapel (freed separately); ddac_free() does NOT touch them.

  /** Attach an ML inference engine handle (from ddac_ml_init).
      When set, ML-dependent stages dispatch to ONNX Runtime. */
  extern proc ddac_set_ml_handle(
    handle: c_ptr(void),
    ml_handle: c_ptr(void)
  ): void;

  /** Attach a GPU OCR coprocessor handle (from ddac_gpu_ocr_init).
      When set, image parsing tries GPU OCR first, falling back to CPU. */
  extern proc ddac_set_gpu_ocr_handle(
    handle: c_ptr(void),
    gpu_ocr_handle: c_ptr(void)
  ): void;

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

  // ── I/O Prefetcher ─────────────────────────────────────────────────────

  /** Initialise I/O prefetcher with a window of upcoming files.
      Uses io_uring on Linux 5.6+, falls back to posix_fadvise. */
  extern proc ddac_prefetch_init(window_size: uint(32)): c_ptr(void);

  /** Hint that a file will be needed soon (triggers kernel readahead). */
  extern proc ddac_prefetch_hint(handle: c_ptr(void), path: c_ptrConst(c_char)): void;

  /** Signal that a file has been fully processed (release page cache). */
  extern proc ddac_prefetch_done(handle: c_ptr(void), path: c_ptrConst(c_char)): void;

  /** Free the prefetcher and close all open files. */
  extern proc ddac_prefetch_free(handle: c_ptr(void)): void;

  /** Get number of files currently being prefetched. */
  extern proc ddac_prefetch_inflight(handle: c_ptr(void)): uint(32);

  // ── Dragonfly / Redis L2 Cache ─────────────────────────────────────────

  /** Connect to Dragonfly/Redis server.
      host_port: "host:port" (e.g., "localhost:6379").
      Returns opaque handle or nil on failure. */
  extern proc ddac_dragonfly_connect(
    host_port: c_ptrConst(c_char)
  ): c_ptr(void);

  /** Close Dragonfly connection and free resources. */
  extern proc ddac_dragonfly_close(handle: c_ptr(void)): void;

  /** Look up a cached result by SHA-256 in Dragonfly.
      Returns 1 (hit) or 0 (miss). On hit, result_out is populated. */
  extern proc ddac_dragonfly_lookup(
    handle: c_ptr(void),
    sha256: c_ptrConst(c_char),
    result_out: c_ptr(void),
    result_size: c_size_t
  ): c_int;

  /** Store a parse result in Dragonfly cache.
      ttl_secs: time-to-live (0 = no expiry). */
  extern proc ddac_dragonfly_store(
    handle: c_ptr(void),
    sha256: c_ptrConst(c_char),
    result: c_ptrConst(void),
    result_size: c_size_t,
    ttl_secs: uint(32)
  ): void;

  /** Get approximate key count in Dragonfly. */
  extern proc ddac_dragonfly_count(handle: c_ptr(void)): uint(64);

  // ── ML Inference Engine (ONNX Runtime) ──────────────────────────────

  /** ML inference result — 56 bytes, matches ddac_ml_result_t.
      status: 0=ok, 1=model_missing, 2=inference_err, 3=input_err, 4=no_onnx */
  extern record ddac_ml_result_t {
    var status: uint(8);              // 0=ok, 1-4=error codes
    var stage: uint(8);               // MlStage enum (0-4)
    var provider: uint(8);            // ExecProvider enum (0-3)
    var _pad: c_array(uint(8), 5);    // alignment padding
    var inference_time_us: int(64);   // inference time (microseconds)
    var output_count: int(64);        // entities/tokens/labels
    var confidence: real(64);         // 0.0-1.0, -1.0 if N/A
    var text_offset: int(64);         // offset into shared text buffer
    var text_length: int(64);         // length of output text
  }

  /** Initialise ML inference engine. Probes for ONNX Runtime. */
  extern proc ddac_ml_init(): c_ptr(void);

  /** Free ML inference engine resources. */
  extern proc ddac_ml_free(handle: c_ptr(void)): void;

  /** Check if ONNX Runtime is available. Returns 1 if yes. */
  extern proc ddac_ml_available(handle: c_ptr(void)): uint(8);

  /** Get execution provider: 0=TensorRT, 1=CUDA, 2=OpenVINO, 3=CPU. */
  extern proc ddac_ml_provider(handle: c_ptr(void)): uint(8);

  /** Get human-readable name for the execution provider. */
  extern proc ddac_ml_provider_name(handle: c_ptr(void)): c_ptrConst(c_char);

  /** Set model directory (expects {stage}.onnx files). */
  extern proc ddac_ml_set_model_dir(
    handle: c_ptr(void),
    dir: c_ptrConst(c_char)
  ): void;

  /** Run an ML stage on a document.
      stage: 0=NER, 1=Whisper, 2=ImageClassify, 3=Layout, 4=Handwriting.
      Returns 0 on dispatch success (check result.status for outcome). */
  extern proc ddac_ml_run_stage(
    handle: c_ptr(void),
    stage: uint(8),
    input_path: c_ptrConst(c_char),
    result_out: c_ptr(void)
  ): c_int;

  /** Get ML inference statistics. */
  extern proc ddac_ml_stats(
    handle: c_ptr(void),
    total_inferences: c_ptr(uint(64)),
    total_inference_us: c_ptr(uint(64))
  ): void;

  /** Get sizeof(ddac_ml_result_t) for allocation. */
  extern proc ddac_ml_result_size(): c_size_t;

  /** Get number of ML stages. */
  extern proc ddac_ml_stage_count(): uint(8);

  /** Get model filename for a stage. */
  extern proc ddac_ml_model_name(stage: uint(8)): c_ptrConst(c_char);

  // ── Hardware Crypto Acceleration ─────────────────────────────────────

  /** Crypto capabilities struct — 16 bytes, matches ddac_crypto_caps_t.
      Reports CPU crypto features for SHA-256 acceleration. */
  extern record ddac_crypto_caps_t {
    var has_sha_ni: uint(8);         // x86-64 SHA-NI
    var has_avx2: uint(8);           // x86-64 AVX2
    var has_avx512: uint(8);         // x86-64 AVX-512F
    var has_arm_sha2: uint(8);       // AArch64 SHA2
    var has_arm_sha512: uint(8);     // AArch64 SHA-512
    var has_aes_ni: uint(8);         // x86-64 AES-NI
    var _pad: c_array(uint(8), 2);   // padding
    var sha256_tier: uint(8);        // 0=dedicated, 1=AVX2, 2=software
    var _pad2: c_array(uint(8), 7);  // padding
  }

  /** Detect hardware crypto capabilities. */
  extern proc ddac_crypto_detect(caps_out: c_ptr(void)): void;

  /** Get SHA-256 acceleration tier: 0=SHA-NI/ARM-SHA2, 1=AVX2, 2=software. */
  extern proc ddac_crypto_sha256_tier(): uint(8);

  /** Get human-readable name for the SHA-256 backend. */
  extern proc ddac_crypto_sha256_name(): c_ptrConst(c_char);

  /** Batch SHA-256: compute digests for N files in parallel.
      Uses multi-buffer technique when AVX2 is available.
      Returns number of successfully hashed files. */
  extern proc ddac_crypto_batch_sha256(
    paths: c_ptr(c_ptrConst(c_char)),
    hex_out: c_ptr(void),
    count: uint(32)
  ): uint(32);

  /** Get sizeof(ddac_crypto_caps_t) for allocation. */
  extern proc ddac_crypto_caps_size(): c_size_t;

  // ── GPU-Accelerated OCR Coprocessor ──────────────────────────────────

  /** OCR result — 48 bytes, matches ddac_ocr_result_t.
      status: 0=success, 1=error, 2=skipped, 3=gpu_error (use CPU fallback). */
  extern record ddac_ocr_result_t {
    var status: uint(8);             // 0=success, 1=error, 2=skipped, 3=gpu_error
    var confidence: int(8);          // OCR confidence 0-100, -1 if unavailable
    var _pad: c_array(uint(8), 6);   // alignment padding
    var char_count: int(64);         // characters extracted
    var word_count: int(64);         // words extracted
    var gpu_time_us: int(64);        // GPU processing time (microseconds)
    var text_offset: int(64);        // offset into shared text buffer
    var text_length: int(64);        // length of extracted text
  }

  /** Initialise GPU OCR coprocessor. Probes for GPU backends.
      Returns opaque handle or nil if init fails. */
  extern proc ddac_gpu_ocr_init(): c_ptr(void);

  /** Free GPU OCR coprocessor resources. */
  extern proc ddac_gpu_ocr_free(handle: c_ptr(void)): void;

  /** Get detected backend: 0=paddle_gpu, 1=tesseract_cuda, 2=cpu_only. */
  extern proc ddac_gpu_ocr_backend(handle: c_ptr(void)): uint(8);

  /** Submit an image for batched GPU OCR.
      Returns slot ID (0..max_batch-1) or -1 if queue full.
      Auto-flushes when the batch fills up. */
  extern proc ddac_gpu_ocr_submit(
    handle: c_ptr(void),
    image_path: c_ptrConst(c_char),
    output_path: c_ptrConst(c_char)
  ): c_int;

  /** Flush pending images — process the current (partial) batch. */
  extern proc ddac_gpu_ocr_flush(handle: c_ptr(void)): void;

  /** Number of results ready after a flush. */
  extern proc ddac_gpu_ocr_results_ready(handle: c_ptr(void)): uint(32);

  /** Collect one OCR result by slot ID.
      Returns 0 on success, -1 on invalid slot. */
  extern proc ddac_gpu_ocr_collect(
    handle: c_ptr(void),
    slot_id: uint(32),
    result_out: c_ptr(void)
  ): c_int;

  /** Get GPU OCR statistics (total submitted, completed, batches, GPU time). */
  extern proc ddac_gpu_ocr_stats(
    handle: c_ptr(void),
    submitted: c_ptr(uint(64)),
    completed: c_ptr(uint(64)),
    batches: c_ptr(uint(64)),
    gpu_time_us: c_ptr(uint(64))
  ): void;

  /** Maximum images per GPU batch. */
  extern proc ddac_gpu_ocr_max_batch(): uint(32);

  /** Get sizeof(ddac_ocr_result_t) for allocation. */
  extern proc ddac_gpu_ocr_result_size(): c_size_t;

  // ── Preprocessing Conduit ────────────────────────────────────────────

  /** Conduit result struct — 88 bytes, matches ddac_conduit_result_t.
      Pre-computed metadata: content kind (magic bytes), validation,
      file size, and SHA-256 digest. */
  extern record ddac_conduit_result_t {
    var content_kind: uint(8);       // ContentKind (0-6) from magic bytes
    var validation: uint(8);         // 0=ok, 1=not_found, 2=empty, 3=unreadable
    var _pad: c_array(uint(8), 6);   // alignment padding
    var file_size: int(64);          // file size in bytes
    var sha256: c_array(c_char, 65); // hex SHA-256 + null
    var _pad2: c_array(c_char, 7);   // alignment padding
  }

  /** Pre-process a single file: detect content type via magic bytes,
      validate accessibility, compute SHA-256.
      Returns 0 on success, non-zero on validation failure. */
  extern proc ddac_conduit_process(
    path: c_ptrConst(c_char),
    result_out: c_ptr(void)
  ): c_int;

  /** Batch pre-process N files.
      Returns number of valid (validation==0) files. */
  extern proc ddac_conduit_batch(
    paths: c_ptr(c_ptrConst(c_char)),
    results: c_ptr(void),
    count: uint(32)
  ): uint(32);

  /** Get sizeof(ddac_conduit_result_t) for Chapel allocation. */
  extern proc ddac_conduit_result_size(): c_size_t;

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
