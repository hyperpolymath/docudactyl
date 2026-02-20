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
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

use Config;
use ContentType;
use FFIBridge;
use ManifestLoader;
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
    writeln("  Cache:   ", cacheDir, " (mode=", cacheMode, ", max=", cacheSizeMB, "MB/locale)");
  if manifestMode != "shared" then
    writeln("  Manifest mode: ", manifestMode);
  writeln("  Chapel: ", chplVersion);
  writeln("═══════════════════════════════════════════════════════════");
  writeln();

  // Print FFI version
  const ver = ddac_version();
  writeln("[init] Zig FFI version: ", string.createCopyingBuffer(ver:c_ptrConst(c_char)));

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

  // ── Load manifest ─────────────────────────────────────────────────
  var docPaths = loadManifest(manifestPath);
  const totalDocs = docPaths.size;

  // ── Initialise subsystems ─────────────────────────────────────────
  initShards();
  resetStats();
  resetFaultCounters();

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

  forall idx in dynamic(docPaths.domain, chunkSize) {
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

    const inputPath = docPaths[idx];
    const outPath = outputPathFor(inputPath);

    var result: ddac_parse_result_t;
    var cacheHit = false;

    // ── Cache lookup ─────────────────────────────────────────────
    if cacheRead && localCacheHandle != nil {
      // Stat the file to get mtime and size
      try {
        var finfo = stat(inputPath);
        const mtime = finfo.mtime: int(64);
        const fsize = finfo.size: int(64);

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
      } catch {
        // stat failed — proceed with normal parse
      }
    }

    // ── Parse (only if cache miss) ───────────────────────────────
    if !cacheHit {
      result = safeParse(handle, inputPath, outPath, fmtCode, stagesMask);

      // ── Cache store ──────────────────────────────────────────
      if cacheWrite && localCacheHandle != nil && parseSucceeded(result) {
        try {
          var finfo = stat(inputPath);
          const mtime = finfo.mtime: int(64);
          const fsize = finfo.size: int(64);

          ddac_cache_store(
            localCacheHandle,
            inputPath.c_str(),
            mtime, fsize,
            c_ptrToConst(result): c_ptrConst(void),
            resultSize
          );
        } catch {
          // stat failed — skip caching
        }
      }
    }

    accumulate(result);
    recordCompletion();

    // Record checkpoint for resume capability
    if parseSucceeded(result) {
      try { recordCheckpoint(idx); } catch { }
    }
  }

  // ── Finalise ──────────────────────────────────────────────────────
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
