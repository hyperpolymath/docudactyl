// Docudactyl HPC — Main Entry Point
//
// Distributed document processing engine for British Library scale corpora.
// Loads a manifest of 170M+ document paths, distributes across Chapel locales,
// parses each document via Zig FFI (→ C libraries), and produces sharded output
// with a global statistics report.
//
// Usage:
//   Single locale:  ./docudactyl-hpc --manifestPath=paths.txt
//   Cluster (64):   ./docudactyl-hpc --manifestPath=paths.txt -nl 64
//   Custom output:  ./docudactyl-hpc --manifestPath=paths.txt --outputDir=results --outputFormat=json
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
use DynamicIters;
use Time;
use CTypes;

proc main() throws {
  writeln("═══════════════════════════════════════════════════════════");
  writeln("  Docudactyl HPC Engine");
  writeln("  Locales: ", numLocales, "  |  Manifest: ", manifestPath);
  writeln("  Output:  ", outputDir, " (", outputFormat, ")");
  writeln("═══════════════════════════════════════════════════════════");
  writeln();

  // Print FFI version
  const ver = ddac_version();
  writeln("[init] Zig FFI version: ", string.createCopyingBuffer(ver:c_ptrConst(c_char)));

  // ── Load manifest ─────────────────────────────────────────────────
  var docPaths = loadManifest(manifestPath);
  const totalDocs = docPaths.size;

  // ── Initialise subsystems ─────────────────────────────────────────
  initShards();
  resetStats();
  resetFaultCounters();
  initProgress(totalDocs);

  // ── Start timer and background progress reporter ──────────────────
  var timer: stopwatch;
  timer.start();
  begin reportLoop(timer);

  // ── Main processing loop ──────────────────────────────────────────
  // Dynamic iteration: Chapel distributes chunks across locales,
  // balancing 2-page pamphlets next to 1000-page manuscripts.

  const fmtCode = outputFormatCode();

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

    // Check for abort before processing
    if shouldAbort() {
      recordCompletion();
      continue;
    }

    const inputPath = docPaths[idx];
    const outPath = outputPathFor(inputPath);

    var result = safeParse(handle, inputPath, outPath, fmtCode);
    accumulate(result);
    recordCompletion();
  }

  // ── Finalise ──────────────────────────────────────────────────────
  timer.stop();
  stopReporter();

  // Give reporter thread time to print final line
  sleep(1.0);

  // Compute and display global statistics
  var report = computeGlobal(timer.elapsed());
  printReport(report);
  writeReport(report, outputDir + "/run-report.scm");

  // Optional: merge shards into single directory
  mergeAllShards();

  writeln("[done] Docudactyl HPC complete.");
}
