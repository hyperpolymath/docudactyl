// Docudactyl HPC — Main Entry Point
//
// Distributed document processing engine for British Library scale corpora.
// Loads a manifest of 170M+ document paths, distributes across Chapel locales,
// parses each document via Zig FFI (-> C libraries), and produces sharded output
// with a global statistics report.
//
// Usage:
//   Single locale:  ./docudactyl-hpc --manifestPath=paths.txt
//   Cluster (64):   ./docudactyl-hpc --manifestPath=paths.txt -nl 64
//   With stages:    ./docudactyl-hpc --manifestPath=paths.txt --stagesConfig=analysis
//   With cache:     ./docudactyl-hpc --manifestPath=paths.txt --cacheDir=/tmp/ddac-cache
//   NDJSON manifest: ./docudactyl-hpc --manifestPath=enriched.ndjson
//   Streaming out:  ./docudactyl-hpc --manifestPath=paths.txt --streamOutput=true
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

use Config;
use ContentType;
use FFIBridge;
use ManifestLoader;
use NdjsonManifest;
use FaultHandler;
use ProgressReporter;
use ShardedOutput;
use ResultAggregator;
use Checkpoint;
use DynamicIters;
use Time;
use CTypes;
use Version;
use FileSystem;
use IO;
use Path;

// Minimum Chapel version required (2.7.0 for --parse-only, begin ref intent)
param DOCUDACTYL_MIN_CHAPEL_MAJOR = 2;
param DOCUDACTYL_MIN_CHAPEL_MINOR = 7;

proc main() throws {
  // ── Version checks ────────────────────────────────────────────────
  if chplVersion.major < DOCUDACTYL_MIN_CHAPEL_MAJOR ||
     (chplVersion.major == DOCUDACTYL_MIN_CHAPEL_MAJOR &&
      chplVersion.minor < DOCUDACTYL_MIN_CHAPEL_MINOR) {
    writeln("[FATAL] Docudactyl HPC requires Chapel >= ",
            DOCUDACTYL_MIN_CHAPEL_MAJOR, ".", DOCUDACTYL_MIN_CHAPEL_MINOR,
            ".0 but running on ", chplVersion);
    return;
  }

  // Parse stages configuration early (needed for banner)
  const stagesMask = parseStagesMask();

  // Determine cache mode
  const cacheEnabled = cacheDir != "" && cacheMode != "off";
  const cacheRead = cacheEnabled && (cacheMode == "read" || cacheMode == "readwrite");
  const cacheWrite = cacheEnabled && (cacheMode == "write" || cacheMode == "readwrite");

  writeln("═══════════════════════════════════════════════════════════");
  writeln("  Docudactyl HPC Engine");
  writeln("  Locales: ", numLocales, "  |  Manifest: ", manifestPath);
  writeln("  Output:  ", outputDir, " (", outputFormat, ")");
  if stagesMask != STAGE_NONE then
    writeln("  Stages:  ", stagesConfig, " (mask=0x", stagesMask:string, ")");
  if cacheEnabled then
    writeln("  Cache L1: ", cacheDir, " (mode=", cacheMode, ", max=", cacheSizeMB, "MB/locale)");
  if dragonflyAddr != "" then
    writeln("  Cache L2: Dragonfly @ ", dragonflyAddr, " (TTL=", dragonflyTTL, "s)");
  if manifestFormat != "auto" then
    writeln("  Manifest format: ", manifestFormat);
  if streamOutput then
    writeln("  Streaming: NDJSON (results.ndjson per shard)");
  if manifestMode != "shared" then
    writeln("  Manifest mode: ", manifestMode);
  if conduitEnabled then
    writeln("  Conduit: magic-byte detection + SHA-256 pre-compute");
  if mlEnabled then
    writeln("  ML stages: ONNX Runtime (models: ", modelDir, ")");
  if gpuOcrEnabled then
    writeln("  GPU OCR: enabled (auto-detect backend)");
  writeln("  Chapel: ", chplVersion);
  writeln("═══════════════════════════════════════════════════════════");
  writeln();

  // Print FFI version
  const ver = ddac_version();
  writeln("[init] Zig FFI version: ", string.createCopyingBuffer(ver:c_ptrConst(c_char)));

  // Report hardware crypto capabilities
  const cryptoName = ddac_crypto_sha256_name();
  writeln("[crypto] SHA-256: ", string.createCopyingBuffer(cryptoName:c_ptrConst(c_char)));

  // ── Initialise LMDB cache (per locale) ─────────────────────────────
  // Each locale gets its own LMDB environment to avoid cross-locale
  // write contention. Reads are zero-copy and fully concurrent.

  var localCacheHandle: c_ptr(void) = nil;

  if cacheEnabled {
    // Create per-locale cache directory
    const localeCacheDir = cacheDir + "/locale-" + here.id:string;
    try {
      mkdir(localeCacheDir, parents=true);
    } catch {
      writeln("[warn] Cannot create cache dir: ", localeCacheDir);
    }

    localCacheHandle = ddac_cache_init(localeCacheDir.c_str(), cacheSizeMB: uint(64));
    if localCacheHandle == nil {
      writeln("[warn] LMDB cache init failed for locale ", here.id, " — running without cache");
    } else {
      const count = ddac_cache_count(localCacheHandle);
      writeln("[cache] Locale ", here.id, ": ", count, " cached entries");
    }
  }

  // ── Initialise I/O prefetcher (per locale) ─────────────────────────
  var prefetchHandle: c_ptr(void) = nil;
  if prefetchWindow > 0 {
    prefetchHandle = ddac_prefetch_init(prefetchWindow: uint(32));
    if prefetchHandle == nil then
      writeln("[warn] I/O prefetcher init failed — running without prefetch");
    else
      writeln("[prefetch] Window: ", prefetchWindow, " files ahead (io_uring/fadvise)");
  }

  // ── Initialise Dragonfly L2 cache (shared across locales) ──────────
  var dragonflyHandle: c_ptr(void) = nil;
  const dragonflyEnabled = dragonflyAddr != "";

  if dragonflyEnabled {
    dragonflyHandle = ddac_dragonfly_connect(dragonflyAddr.c_str());
    if dragonflyHandle == nil {
      writeln("[warn] Dragonfly connection failed (", dragonflyAddr, ") — running without L2 cache");
    } else {
      const l2Count = ddac_dragonfly_count(dragonflyHandle);
      writeln("[cache-l2] Connected to Dragonfly: ", l2Count, " cached entries");
    }
  }

  // ── Initialise ML inference engine (per locale) ──────────────────
  var mlHandle: c_ptr(void) = nil;
  if mlEnabled {
    mlHandle = ddac_ml_init();
    if mlHandle == nil {
      writeln("[warn] ML inference init failed — ML stages will be skipped");
    } else {
      ddac_ml_set_model_dir(mlHandle, modelDir.c_str());
      const mlAvail = ddac_ml_available(mlHandle);
      if mlAvail == 1 {
        const provName = ddac_ml_provider_name(mlHandle);
        writeln("[ml] ONNX Runtime: ", string.createCopyingBuffer(provName:c_ptrConst(c_char)),
                " | models: ", modelDir);
      } else {
        writeln("[warn] ONNX Runtime not found — ML stages will return status=4");
      }
    }
  }

  // ── Initialise GPU OCR coprocessor (per locale) ──────────────────
  var gpuOcrHandle: c_ptr(void) = nil;
  if gpuOcrEnabled && conduitEnabled {
    gpuOcrHandle = ddac_gpu_ocr_init();
    if gpuOcrHandle == nil {
      writeln("[warn] GPU OCR init failed — using CPU Tesseract for all images");
    } else {
      const backendId = ddac_gpu_ocr_backend(gpuOcrHandle);
      const backendName = if backendId == 0 then "PaddleOCR (CUDA/TensorRT)"
                          else if backendId == 1 then "Tesseract CUDA"
                          else "CPU only (no GPU detected)";
      const maxBatch = ddac_gpu_ocr_max_batch();
      writeln("[gpu-ocr] Backend: ", backendName, " | batch size: ", maxBatch);
    }
  }

  // ── Load manifest ─────────────────────────────────────────────────
  var docEntries = loadManifest(manifestPath);
  const totalDocs = docEntries.size;

  // ── Initialise subsystems ─────────────────────────────────────────
  initShards();
  resetStats();
  resetFaultCounters();

  // ── Initialise streaming NDJSON writer (per locale) ───────────────
  var ndjsonWriter: NdjsonWriter;
  if streamOutput {
    ndjsonWriter = initNdjsonWriter(shardDir(here.id));
    writeln("[stream] NDJSON streaming output enabled for locale ", here.id);
  }

  // ── Resume from checkpoint if --resume is set ─────────────────────
  loadCheckpoint();

  initProgress(totalDocs);

  // ── Start timer and background progress reporter ──────────────────
  var timer: stopwatch;
  timer.start();
  begin with (ref timer) reportLoop(timer);

  // ── Main processing loop ──────────────────────────────────────────
  // Dynamic iteration: Chapel distributes chunks across locales,
  // balancing 2-page pamphlets next to 1000-page manuscripts.

  const fmtCode = outputFormatCode();
  const resultSize: c_size_t = 952; // sizeof(ddac_parse_result_t)

  forall idx in dynamic(docEntries.domain, chunkSize) {
    // Each task gets its own FFI handle (owns Tesseract/GDAL contexts)
    var handle = ddac_init();
    defer ddac_free(handle);

    if handle == nil {
      writeln("[error] ddac_init failed on locale ", here.id);
      recordFailure();
      recordCompletion();
      continue;
    }

    // Skip if already processed in a previous run (--resume)
    if isAlreadyProcessed(idx) {
      recordCompletion();
      continue;
    }

    // Check for abort before processing
    if shouldAbort() {
      recordCompletion();
      continue;
    }

    const entry = docEntries[idx];
    const inputPath = entry.path;
    const outPath = outputPathFor(inputPath);

    // Prefetch hint — tell kernel to start loading this file into page cache
    if prefetchHandle != nil then
      ddac_prefetch_hint(prefetchHandle, inputPath.c_str());

    // ── Conduit pre-processing ─────────────────────────────────────
    // Lightweight validation + magic-byte detection + SHA-256 pre-computation.
    // Runs before the full parse to:
    //   1. Skip invalid/empty/missing files early (no Tesseract/Poppler init)
    //   2. Provide SHA-256 for L2 Dragonfly lookup even on cold runs
    //   3. Record content type from magic bytes (more accurate than extension)
    //   4. Capture file size without a separate stat() call

    var conduitResult: ddac_conduit_result_t;
    var conduitValid = false;

    if conduitEnabled {
      const conduitRc = ddac_conduit_process(
        inputPath.c_str(),
        c_ptrTo(conduitResult): c_ptr(void)
      );

      // Skip invalid files — conduit detected a problem before the expensive parse
      if conduitRc != 0 {
        if conduitResult.validation == 1 then
          writeln("[skip] Not found: ", inputPath);
        else if conduitResult.validation == 2 then
          writeln("[skip] Empty: ", inputPath);
        else
          writeln("[skip] Unreadable: ", inputPath);
        recordFailure();
        recordCompletion();
        if prefetchHandle != nil then
          ddac_prefetch_done(prefetchHandle, inputPath.c_str());
        continue;
      }

      conduitValid = true;
      // Record the content type detected by magic bytes
      recordContentType(conduitResult.content_kind: int);
    }

    var result: ddac_parse_result_t;
    var cacheHit = false;

    // ── Cache lookup ─────────────────────────────────────────────
    // When NDJSON manifest provides pre-computed mtime/size, skip stat().
    // When conduit ran, use its file_size (avoids a second stat).
    if cacheRead && localCacheHandle != nil {
      var mtime: int(64) = -1;
      var fsize: int(64) = -1;

      if entry.hasMetadata() {
        // Use pre-computed metadata — no stat() needed
        mtime = entry.mtime;
        fsize = entry.size;
      } else if conduitValid {
        // Use conduit file_size, but still need mtime from stat()
        fsize = conduitResult.file_size;
        try {
          var finfo = stat(inputPath);
          mtime = finfo.mtime: int(64);
        } catch {
          // stat failed — proceed with normal parse
        }
      } else {
        // Fall back to stat() for plain manifests without conduit
        try {
          var finfo = stat(inputPath);
          mtime = finfo.mtime: int(64);
          fsize = finfo.size: int(64);
        } catch {
          // stat failed — proceed with normal parse
        }
      }

      if mtime >= 0 && fsize >= 0 {
        const hit = ddac_cache_lookup(
          localCacheHandle,
          inputPath.c_str(),
          mtime, fsize,
          c_ptrTo(result): c_ptr(void),
          resultSize
        );

        if hit == 1 {
          cacheHit = true;
          recordSuccess();
        }
      }
    }

    // ── L2 Dragonfly lookup (cross-locale dedup) ──────────────────
    // When conduit ran, SHA-256 is pre-computed, so L2 lookup works
    // on cold runs too (previously sha256 was uninitialized without L1 hit).
    if !cacheHit && dragonflyHandle != nil {
      var sha: string;
      if conduitValid {
        sha = string.createCopyingBuffer(conduitResult.sha256: c_ptrConst(c_char));
      } else {
        sha = string.createCopyingBuffer(result.sha256: c_ptrConst(c_char));
      }
      if sha.size >= 64 {
        const l2Hit = ddac_dragonfly_lookup(
          dragonflyHandle,
          sha.c_str(),
          c_ptrTo(result): c_ptr(void),
          resultSize
        );
        if l2Hit == 1 {
          cacheHit = true;
          recordSuccess();
        }
      }
    }

    // ── Parse (only if both L1 and L2 missed) ────────────────────
    if !cacheHit {
      result = safeParse(handle, inputPath, outPath, fmtCode, stagesMask);

      // ── L1 cache store ──────────────────────────────────────
      if cacheWrite && localCacheHandle != nil && parseSucceeded(result) {
        var mtime: int(64) = -1;
        var fsize: int(64) = -1;

        if entry.hasMetadata() {
          mtime = entry.mtime;
          fsize = entry.size;
        } else {
          try {
            var finfo = stat(inputPath);
            mtime = finfo.mtime: int(64);
            fsize = finfo.size: int(64);
          } catch {
            // stat failed — skip caching
          }
        }

        if mtime >= 0 && fsize >= 0 {
          ddac_cache_store(
            localCacheHandle,
            inputPath.c_str(),
            mtime, fsize,
            c_ptrToConst(result): c_ptrConst(void),
            resultSize
          );
        }
      }

      // ── L2 Dragonfly store (cross-locale dedup) ─────────────
      if dragonflyHandle != nil && parseSucceeded(result) {
        const sha = string.createCopyingBuffer(result.sha256: c_ptrConst(c_char));
        if sha.size >= 64 {
          ddac_dragonfly_store(
            dragonflyHandle,
            sha.c_str(),
            c_ptrToConst(result): c_ptrConst(void),
            resultSize,
            dragonflyTTL: uint(32)
          );
        }
      }
    }

    // Signal prefetcher that this file is done (release page cache)
    if prefetchHandle != nil then
      ddac_prefetch_done(prefetchHandle, inputPath.c_str());

    accumulate(result);
    recordCompletion();

    // Write streaming NDJSON result if enabled
    if streamOutput {
      ndjsonWriter.writeResult(inputPath, result, result.parse_time_ms);
    }

    // Record checkpoint for resume capability
    if parseSucceeded(result) {
      try { recordCheckpoint(idx); } catch { }
    }
  }

  // ── Finalise ──────────────────────────────────────────────────────
  if streamOutput then ndjsonWriter.flush();
  timer.stop();
  stopReporter();

  // Give reporter thread time to print final line
  sleep(1.0);

  // Sync and close cache
  if localCacheHandle != nil {
    ddac_cache_sync(localCacheHandle);
    const finalCount = ddac_cache_count(localCacheHandle);
    writeln("[cache] Locale ", here.id, ": ", finalCount, " entries after run");
    ddac_cache_free(localCacheHandle);
  }

  // Close I/O prefetcher
  if prefetchHandle != nil then
    ddac_prefetch_free(prefetchHandle);

  // Close Dragonfly L2 cache
  if dragonflyHandle != nil {
    const l2Final = ddac_dragonfly_count(dragonflyHandle);
    writeln("[cache-l2] Dragonfly: ", l2Final, " entries after run");
    ddac_dragonfly_close(dragonflyHandle);
  }

  // Close GPU OCR coprocessor and print stats
  if gpuOcrHandle != nil {
    var gpuSubmitted, gpuCompleted, gpuBatches, gpuTimeUs: uint(64);
    ddac_gpu_ocr_stats(gpuOcrHandle,
      c_ptrTo(gpuSubmitted), c_ptrTo(gpuCompleted),
      c_ptrTo(gpuBatches), c_ptrTo(gpuTimeUs));
    writeln("[gpu-ocr] ", gpuSubmitted, " submitted, ", gpuCompleted, " completed, ",
            gpuBatches, " batches, ", gpuTimeUs / 1000, "ms GPU time");
    ddac_gpu_ocr_free(gpuOcrHandle);
  }

  // Close ML inference engine
  if mlHandle != nil {
    var mlInferences, mlTimeUs: uint(64);
    ddac_ml_stats(mlHandle, c_ptrTo(mlInferences), c_ptrTo(mlTimeUs));
    if mlInferences > 0 then
      writeln("[ml] ", mlInferences, " inferences, ", mlTimeUs / 1000, "ms total");
    ddac_ml_free(mlHandle);
  }

  // Compute and display global statistics
  var report = computeGlobal(timer.elapsed());
  printReport(report);
  writeReport(report, outputDir + "/run-report.scm");
  writeJSONReport(report, outputDir + "/run-report.json");

  // Save final checkpoint (for resume if needed later)
  try { flushAllCheckpoints(); } catch { }

  // Optional: merge shards into single directory
  mergeAllShards();

  // Clear checkpoint files on successful completion
  if report.failedDocs == 0 {
    try { clearCheckpoints(); } catch { }
  }

  writeln("[done] Docudactyl HPC complete.");
}
