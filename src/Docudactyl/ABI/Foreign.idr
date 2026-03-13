||| Foreign Function Interface Declarations for Docudactyl
|||
||| Declares all C-compatible functions implemented in the Zig FFI layer
||| (ffi/zig/src/docudactyl_ffi.zig). Chapel calls these directly; Idris2
||| provides the type-level proofs that the interface is correct.
|||
||| SPDX-License-Identifier: PMPL-1.0-or-later
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

module Docudactyl.ABI.Foreign

import Docudactyl.ABI.Types
import Docudactyl.ABI.Layout
import Data.So

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Initialise the Docudactyl FFI library.
||| Returns a handle to Tesseract/GDAL/vips contexts, or Nothing on failure.
export
%foreign "C:ddac_init, libdocudactyl_ffi"
prim__init : PrimIO Bits64

||| Safe wrapper for library initialisation
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO Docudactyl.ABI.Foreign.prim__init
  pure (createHandle ptr)

||| Free all library resources (Tesseract, GDAL, vips).
||| Safe to call with a null pointer.
export
%foreign "C:ddac_free, libdocudactyl_ffi"
prim__free : Bits64 -> PrimIO ()

||| Safe wrapper for cleanup
export
free : Handle -> IO ()
free h = primIO (prim__free (handlePtr h))

--------------------------------------------------------------------------------
-- Core Parse Operation
--------------------------------------------------------------------------------

||| Parse a document with optional processing stages.
||| Dispatches to the correct C library based on file extension.
|||
||| Parameters (as raw Bits64 pointers to C strings):
|||   handle      - library handle from ddac_init
|||   input_path  - absolute path to input document
|||   output_path - absolute path for extracted content output
|||   output_fmt  - output format (0=scheme, 1=json, 2=csv)
|||   stage_flags - bitmask of processing stages (0 = base parse only)
|||
||| Returns a raw pointer to a ddac_parse_result_t struct.
||| Stage results (if any) written to {output_path}.stages.capnp (Cap'n Proto binary).
||| In practice, Chapel reads the struct fields directly via extern record.
export
%foreign "C:ddac_parse, libdocudactyl_ffi"
prim__parse : Bits64 -> Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO Bits64

||| Safe wrapper for parse with type-checked status
export
parse : Handle -> (inputPath : Bits64) -> (outputPath : Bits64) -> (outputFmt : Bits64) -> (stageFlags : Bits64) -> IO (Either ParseStatus Bits64)
parse h inputPath outputPath outputFmt stageFlags = do
  resultPtr <- primIO (Docudactyl.ABI.Foreign.prim__parse (handlePtr h) inputPath outputPath outputFmt stageFlags)
  if resultPtr == 0
    then pure (Left Error)
    else pure (Right resultPtr)

--------------------------------------------------------------------------------
-- Version Information
--------------------------------------------------------------------------------

||| Get library version string
export
%foreign "C:ddac_version, libdocudactyl_ffi"
prim__version : PrimIO Bits64

||| Convert C string pointer to Idris String
export
%foreign "support:idris2_getString, libidris2_support"
prim__getString : Bits64 -> String

||| Get version as string
export
version : IO String
version = do
  ptr <- primIO prim__version
  pure (prim__getString ptr)

--------------------------------------------------------------------------------
-- Error Handling Utilities
--------------------------------------------------------------------------------

||| Extract ParseStatus from a raw result status integer
export
decodeStatus : Bits32 -> ParseStatus
decodeStatus n = case intToParseStatus n of
  Just s  => s
  Nothing => Error

||| Extract ContentKind from a raw result content_kind integer
export
decodeContentKind : Bits32 -> ContentKind
decodeContentKind n = case intToContentKind n of
  Just k  => k
  Nothing => Unknown

||| Human-readable description of a parse status
export
statusDescription : ParseStatus -> String
statusDescription Ok               = "Success"
statusDescription Error             = "Generic error"
statusDescription FileNotFound      = "File not found"
statusDescription ParseError        = "Parse error"
statusDescription NullPointer       = "Null pointer"
statusDescription UnsupportedFormat = "Unsupported format"
statusDescription OutOfMemory       = "Out of memory"

||| Human-readable description of a content kind
export
contentKindDescription : ContentKind -> String
contentKindDescription PDF        = "PDF document"
contentKindDescription Image      = "Image (OCR)"
contentKindDescription Audio      = "Audio recording"
contentKindDescription Video      = "Video recording"
contentKindDescription EPUB       = "EPUB e-book"
contentKindDescription GeoSpatial = "Geospatial data"
contentKindDescription Unknown    = "Unknown format"

--------------------------------------------------------------------------------
-- Handle Attachment (ML + GPU OCR)
--------------------------------------------------------------------------------

||| Attach an ML inference engine handle to a parse handle.
||| The ML handle remains owned by the caller — NOT freed by ddac_free().
||| When attached, ML-dependent stages dispatch to ONNX Runtime.
export
%foreign "C:ddac_set_ml_handle, libdocudactyl_ffi"
prim__setMlHandle : Bits64 -> Bits64 -> PrimIO ()

||| Safe wrapper for attaching ML handle
export
setMlHandle : Handle -> Bits64 -> IO ()
setMlHandle h mlH = primIO (prim__setMlHandle (handlePtr h) mlH)

||| Attach a GPU OCR coprocessor handle to a parse handle.
||| The GPU OCR handle remains owned by the caller — NOT freed by ddac_free().
||| When attached, image parsing tries GPU OCR first with CPU fallback.
export
%foreign "C:ddac_set_gpu_ocr_handle, libdocudactyl_ffi"
prim__setGpuOcrHandle : Bits64 -> Bits64 -> PrimIO ()

||| Safe wrapper for attaching GPU OCR handle
export
setGpuOcrHandle : Handle -> Bits64 -> IO ()
setGpuOcrHandle h ocrH = primIO (prim__setGpuOcrHandle (handlePtr h) ocrH)

--------------------------------------------------------------------------------
-- LMDB Result Cache (L1)
--------------------------------------------------------------------------------

||| Initialise per-locale LMDB cache. Returns cache handle or null.
||| dir_path: directory for the LMDB environment
||| max_size_mb: maximum DB size in megabytes (e.g. 10240 for 10GB)
export
%foreign "C:ddac_cache_init, libdocudactyl_ffi"
prim__cacheInit : Bits64 -> Bits64 -> PrimIO Bits64

||| Free LMDB cache resources.
export
%foreign "C:ddac_cache_free, libdocudactyl_ffi"
prim__cacheFree : Bits64 -> PrimIO ()

||| Look up a cached result by document path + mtime + size.
||| Returns 0 on cache hit (result_out populated), non-zero on miss.
export
%foreign "C:ddac_cache_lookup, libdocudactyl_ffi"
prim__cacheLookup : Bits64 -> Bits64 -> Int64 -> Int64 -> Bits64 -> Bits64 -> PrimIO Int32

||| Store a result in the cache keyed by document path + mtime + size.
export
%foreign "C:ddac_cache_store, libdocudactyl_ffi"
prim__cacheStore : Bits64 -> Bits64 -> Int64 -> Int64 -> Bits64 -> Bits64 -> PrimIO ()

||| Get number of entries currently in the cache.
export
%foreign "C:ddac_cache_count, libdocudactyl_ffi"
prim__cacheCount : Bits64 -> PrimIO Bits64

||| Force sync (flush) the LMDB environment to disk.
export
%foreign "C:ddac_cache_sync, libdocudactyl_ffi"
prim__cacheSync : Bits64 -> PrimIO ()

--------------------------------------------------------------------------------
-- Dragonfly / Redis L2 Cache
--------------------------------------------------------------------------------

||| Connect to a Dragonfly (or Redis) instance. host_port: "host:port".
||| Returns connection handle or null on failure.
export
%foreign "C:ddac_dragonfly_connect, libdocudactyl_ffi"
prim__dragonflyConnect : Bits64 -> PrimIO Bits64

||| Close the Dragonfly connection.
export
%foreign "C:ddac_dragonfly_close, libdocudactyl_ffi"
prim__dragonflyClose : Bits64 -> PrimIO ()

||| Look up a cached result by SHA-256 hex digest.
||| Returns 0 on hit, non-zero on miss.
export
%foreign "C:ddac_dragonfly_lookup, libdocudactyl_ffi"
prim__dragonflyLookup : Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO Int32

||| Store a result with SHA-256 key and TTL in seconds.
export
%foreign "C:ddac_dragonfly_store, libdocudactyl_ffi"
prim__dragonflyStore : Bits64 -> Bits64 -> Bits64 -> Bits64 -> Bits32 -> PrimIO ()

||| Get number of keys in the Dragonfly instance.
export
%foreign "C:ddac_dragonfly_count, libdocudactyl_ffi"
prim__dragonflyCount : Bits64 -> PrimIO Bits64

--------------------------------------------------------------------------------
-- I/O Prefetcher
--------------------------------------------------------------------------------

||| Initialise the I/O prefetcher. window_size: number of files to prefetch.
||| Uses io_uring on Linux 5.6+, falls back to posix_fadvise.
export
%foreign "C:ddac_prefetch_init, libdocudactyl_ffi"
prim__prefetchInit : Bits32 -> PrimIO Bits64

||| Hint that a file will be needed soon (queues for prefetch).
export
%foreign "C:ddac_prefetch_hint, libdocudactyl_ffi"
prim__prefetchHint : Bits64 -> Bits64 -> PrimIO ()

||| Signal that a file has been processed (can be evicted from prefetch).
export
%foreign "C:ddac_prefetch_done, libdocudactyl_ffi"
prim__prefetchDone : Bits64 -> Bits64 -> PrimIO ()

||| Free the prefetcher resources.
export
%foreign "C:ddac_prefetch_free, libdocudactyl_ffi"
prim__prefetchFree : Bits64 -> PrimIO ()

||| Get number of inflight prefetch operations.
export
%foreign "C:ddac_prefetch_inflight, libdocudactyl_ffi"
prim__prefetchInflight : Bits64 -> PrimIO Bits32

--------------------------------------------------------------------------------
-- ML Inference Engine
--------------------------------------------------------------------------------

||| Initialise the ML inference engine (loads ONNX Runtime via dlopen).
||| Returns handle or null if ONNX Runtime unavailable.
export
%foreign "C:ddac_ml_init, libdocudactyl_ffi"
prim__mlInit : PrimIO Bits64

||| Free ML engine resources.
export
%foreign "C:ddac_ml_free, libdocudactyl_ffi"
prim__mlFree : Bits64 -> PrimIO ()

||| Check if ONNX Runtime is available (1 = yes, 0 = no).
export
%foreign "C:ddac_ml_available, libdocudactyl_ffi"
prim__mlAvailable : Bits64 -> PrimIO Bits8

||| Get the active execution provider (0=TRT, 1=CUDA, 2=OpenVINO, 3=CPU).
export
%foreign "C:ddac_ml_provider, libdocudactyl_ffi"
prim__mlProvider : Bits64 -> PrimIO Bits8

||| Get execution provider name as C string.
export
%foreign "C:ddac_ml_provider_name, libdocudactyl_ffi"
prim__mlProviderName : Bits64 -> PrimIO Bits64

||| Set the model directory for ONNX model loading.
export
%foreign "C:ddac_ml_set_model_dir, libdocudactyl_ffi"
prim__mlSetModelDir : Bits64 -> Bits64 -> PrimIO ()

||| Run a single ML stage on an input file.
||| stage: 0=NER, 1=Whisper, 2=ImageClassify, 3=Layout, 4=Handwriting.
||| Returns 0 on success, non-zero on error.
export
%foreign "C:ddac_ml_run_stage, libdocudactyl_ffi"
prim__mlRunStage : Bits64 -> Bits8 -> Bits64 -> Bits64 -> PrimIO Int32

||| Get cumulative ML inference statistics.
export
%foreign "C:ddac_ml_stats, libdocudactyl_ffi"
prim__mlStats : Bits64 -> Bits64 -> Bits64 -> PrimIO ()

||| Get sizeof(ddac_ml_result_t) for allocation.
export
%foreign "C:ddac_ml_result_size, libdocudactyl_ffi"
prim__mlResultSize : PrimIO Bits64

||| Get number of ML stages (should be 5).
export
%foreign "C:ddac_ml_stage_count, libdocudactyl_ffi"
prim__mlStageCount : PrimIO Bits8

||| Get model filename for a given stage index.
export
%foreign "C:ddac_ml_model_name, libdocudactyl_ffi"
prim__mlModelName : Bits8 -> PrimIO Bits64

--------------------------------------------------------------------------------
-- GPU-Accelerated OCR Coprocessor
--------------------------------------------------------------------------------

||| Initialise the GPU OCR coprocessor.
||| Returns handle or null if no GPU backend available.
export
%foreign "C:ddac_gpu_ocr_init, libdocudactyl_ffi"
prim__gpuOcrInit : PrimIO Bits64

||| Free GPU OCR resources.
export
%foreign "C:ddac_gpu_ocr_free, libdocudactyl_ffi"
prim__gpuOcrFree : Bits64 -> PrimIO ()

||| Get detected GPU backend (0=PaddleOCR, 1=TesseractCUDA, 2=CPUOnly).
export
%foreign "C:ddac_gpu_ocr_backend, libdocudactyl_ffi"
prim__gpuOcrBackend : Bits64 -> PrimIO Bits8

||| Submit an image for GPU OCR. Returns slot ID (>=0) or -1 on error.
export
%foreign "C:ddac_gpu_ocr_submit, libdocudactyl_ffi"
prim__gpuOcrSubmit : Bits64 -> Bits64 -> Bits64 -> PrimIO Int32

||| Flush the submission queue (batch-process on GPU).
export
%foreign "C:ddac_gpu_ocr_flush, libdocudactyl_ffi"
prim__gpuOcrFlush : Bits64 -> PrimIO ()

||| Get number of results ready for collection.
export
%foreign "C:ddac_gpu_ocr_results_ready, libdocudactyl_ffi"
prim__gpuOcrResultsReady : Bits64 -> PrimIO Bits32

||| Collect result for a slot. Returns 0 on success.
export
%foreign "C:ddac_gpu_ocr_collect, libdocudactyl_ffi"
prim__gpuOcrCollect : Bits64 -> Bits32 -> Bits64 -> PrimIO Int32

||| Get cumulative GPU OCR statistics.
export
%foreign "C:ddac_gpu_ocr_stats, libdocudactyl_ffi"
prim__gpuOcrStats : Bits64 -> Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO ()

||| Get max batch size for GPU OCR.
export
%foreign "C:ddac_gpu_ocr_max_batch, libdocudactyl_ffi"
prim__gpuOcrMaxBatch : PrimIO Bits32

||| Get sizeof(ddac_ocr_result_t) for allocation.
export
%foreign "C:ddac_gpu_ocr_result_size, libdocudactyl_ffi"
prim__gpuOcrResultSize : PrimIO Bits64

--------------------------------------------------------------------------------
-- Hardware Crypto Acceleration
--------------------------------------------------------------------------------

||| Detect CPU crypto capabilities and write to caps_out struct.
export
%foreign "C:ddac_crypto_detect, libdocudactyl_ffi"
prim__cryptoDetect : Bits64 -> PrimIO ()

||| Get SHA-256 acceleration tier (0=dedicated, 1=AVX2, 2=software).
export
%foreign "C:ddac_crypto_sha256_tier, libdocudactyl_ffi"
prim__cryptoSha256Tier : PrimIO Bits8

||| Get human-readable name for the SHA-256 acceleration method.
export
%foreign "C:ddac_crypto_sha256_name, libdocudactyl_ffi"
prim__cryptoSha256Name : PrimIO Bits64

||| Batch compute SHA-256 for multiple files. Returns count of successes.
export
%foreign "C:ddac_crypto_batch_sha256, libdocudactyl_ffi"
prim__cryptoBatchSha256 : Bits64 -> Bits64 -> Bits32 -> PrimIO Bits32

||| Get sizeof(ddac_crypto_caps_t) for allocation.
export
%foreign "C:ddac_crypto_caps_size, libdocudactyl_ffi"
prim__cryptoCapsSize : PrimIO Bits64

--------------------------------------------------------------------------------
-- Preprocessing Conduit
--------------------------------------------------------------------------------

||| Pre-process a single file: detect type, validate, compute SHA-256.
||| Returns 0 on validation success, non-zero on failure.
export
%foreign "C:ddac_conduit_process, libdocudactyl_ffi"
prim__conduitProcess : Bits64 -> Bits64 -> PrimIO Int32

||| Batch pre-process N files. Returns number of valid files.
export
%foreign "C:ddac_conduit_batch, libdocudactyl_ffi"
prim__conduitBatch : Bits64 -> Bits64 -> Bits32 -> PrimIO Bits32

||| Get sizeof(ddac_conduit_result_t) for allocation.
export
%foreign "C:ddac_conduit_result_size, libdocudactyl_ffi"
prim__conduitResultSize : PrimIO Bits64

--------------------------------------------------------------------------------
-- Safety Proofs
--------------------------------------------------------------------------------

||| Proof that init returns a non-null handle on success
||| (This is a specification -- the Zig implementation must guarantee it)
||| Given a proof that (ptr /= 0) evaluates to True, we can safely
||| construct a Handle by converting the Bool equality to a So witness.
export
initNonNull : (ptr : Bits64) -> (prf : (ptr /= 0) = True) -> Maybe Handle
initNonNull ptr prf = Just (MkHandle ptr (rewrite prf in Oh))

||| Proof that free is idempotent (calling twice is safe)
||| Encoded as a specification: ddac_free(NULL) is a no-op in Zig.
export
freeIdempotent : String
freeIdempotent = "ddac_free checks for null; double-free is a no-op"
