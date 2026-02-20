// Docudactyl HPC — Fault Handler
//
// Per-document fault isolation with retry logic.
// Wraps ddac_parse with retry loop and tracks failure rates
// per locale to detect systematic problems.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module FaultHandler {
  use FFIBridge;
  use Config;
  use CTypes;

  // ── Per-locale failure tracking ───────────────────────────────────────

  /** Atomic counters for per-locale success/failure tracking.
      Each locale maintains its own instance. */
  var localeSuccessCount: atomic int;
  var localeFailureCount: atomic int;

  /** Reset counters (call at start of run). */
  proc resetFaultCounters() {
    localeSuccessCount.write(0);
    localeFailureCount.write(0);
  }

  /** Record a successful parse. */
  proc recordSuccess() {
    localeSuccessCount.add(1);
  }

  /** Record a failed parse. */
  proc recordFailure() {
    localeFailureCount.add(1);
  }

  /** Get current failure rate as a percentage.
      Returns 0.0 if fewer than minSamples have been processed. */
  proc currentFailureRate(minSamples: int = 1000): real {
    const total = localeSuccessCount.read() + localeFailureCount.read();
    if total < minSamples then return 0.0;
    return (localeFailureCount.read(): real / total: real) * 100.0;
  }

  /** Check if the run should abort due to excessive failures.
      Only triggers after 1000+ documents have been processed. */
  proc shouldAbort(): bool {
    const total = localeSuccessCount.read() + localeFailureCount.read();
    if total < 1000 then return false;
    return currentFailureRate() > failureThresholdPct;
  }

  // ── Safe parse with retry ─────────────────────────────────────────────

  /** Parse a document with retry logic and fault isolation.

      - Retries up to maxRetriesPerDoc times on transient errors
      - Records success/failure for abort detection
      - Returns the parse result (check status field for errors)

      handle:     from ddac_init()
      inputPath:  absolute path to source document
      outputPath: absolute path for extracted content
      fmtCode:    output format (0=scheme, 1=json, 2=csv)
      stagesMask: bitmask of processing stages to run (0 = none) */
  proc safeParse(
    handle: c_ptr(void),
    inputPath: string,
    outputPath: string,
    fmtCode: int,
    stagesMask: uint(64) = 0
  ): ddac_parse_result_t {

    var result: ddac_parse_result_t;
    var attempts = 0;

    while attempts <= maxRetriesPerDoc {
      result = ddac_parse(
        handle,
        inputPath.c_str(),
        outputPath.c_str(),
        fmtCode: c_int,
        stagesMask
      );

      if parseSucceeded(result) {
        recordSuccess();
        return result;
      }

      // Status 5 = UnsupportedFormat, 2 = FileNotFound — not retryable
      if result.status == 5 || result.status == 2 {
        recordFailure();
        return result;
      }

      attempts += 1;
      if attempts <= maxRetriesPerDoc then
        writeln("[fault] Retry ", attempts, "/", maxRetriesPerDoc,
                " for: ", inputPath);
    }

    // All retries exhausted
    recordFailure();
    return result;
  }

  /** Get a summary of fault statistics for this locale. */
  proc faultSummary(): string {
    const succ = localeSuccessCount.read();
    const fail = localeFailureCount.read();
    const total = succ + fail;
    const rate = if total > 0 then (fail: real / total: real) * 100.0 else 0.0;
    return "locale " + here.id:string + ": " +
           succ:string + " ok, " + fail:string + " failed (" +
           rate:string + "%)";
  }
}
