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
  use Time;

  // ── Per-locale failure tracking ───────────────────────────────────────

  /** Atomic counters for per-locale success/failure tracking.
      Each locale maintains its own instance. */
  var localeSuccessCount: atomic int;
  var localeFailureCount: atomic int;

  /** Straggler tracking — documents exceeding a time threshold. */
  var localeTimeoutCount: atomic int;
  var localeSlowestMs: atomic int;   // longest parse time seen (milliseconds)
  var localeTotalMs: atomic int;     // sum of all parse times (for average)

  /** Per-content-type counters (ContentKind enum: 0-6). */
  var contentTypeCounts: [0..6] atomic int;

  /** Reset counters (call at start of run). */
  proc resetFaultCounters() {
    localeSuccessCount.write(0);
    localeFailureCount.write(0);
    localeTimeoutCount.write(0);
    localeSlowestMs.write(0);
    localeTotalMs.write(0);
    for i in 0..6 do contentTypeCounts[i].write(0);
  }

  /** Record a successful parse with timing. */
  proc recordSuccess() {
    localeSuccessCount.add(1);
  }

  /** Record parse timing in milliseconds. */
  proc recordTiming(ms: int) {
    localeTotalMs.add(ms);
    // Update slowest (atomic CAS loop)
    var current = localeSlowestMs.read();
    while ms > current {
      if localeSlowestMs.compareExchange(current, ms) then break;
      current = localeSlowestMs.read();
    }
  }

  /** Record a content type encounter. */
  proc recordContentType(kind: int) {
    if kind >= 0 && kind <= 6 then
      contentTypeCounts[kind].add(1);
  }

  /** Record a timed-out document. */
  proc recordTimeout() {
    localeTimeoutCount.add(1);
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
    var parseTimer: stopwatch;

    while attempts <= maxRetriesPerDoc {
      parseTimer.start();

      result = ddac_parse(
        handle,
        inputPath.c_str(),
        outputPath.c_str(),
        fmtCode: c_int,
        stagesMask
      );

      parseTimer.stop();
      const elapsedMs = (parseTimer.elapsed() * 1000.0): int;
      recordTiming(elapsedMs);
      recordContentType(result.content_kind: int);

      // Check for straggler (exceeds timeout threshold)
      if elapsedMs > timeoutPerDocMs {
        recordTimeout();
        writeln("[straggler] ", inputPath, " took ", elapsedMs, "ms (timeout=", timeoutPerDocMs, "ms)");
      }

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
      parseTimer.reset();
    }

    // All retries exhausted
    recordFailure();
    return result;
  }

  /** Get a summary of fault statistics for this locale. */
  proc faultSummary(): string {
    const succ = localeSuccessCount.read();
    const fail = localeFailureCount.read();
    const timeouts = localeTimeoutCount.read();
    const total = succ + fail;
    const rate = if total > 0 then (fail: real / total: real) * 100.0 else 0.0;
    const avgMs = if total > 0 then localeTotalMs.read(): real / total: real else 0.0;
    const slowest = localeSlowestMs.read();
    return "locale " + here.id:string + ": " +
           succ:string + " ok, " + fail:string + " failed (" +
           rate:string + "%), " +
           timeouts:string + " stragglers, " +
           "avg=" + avgMs:string + "ms, max=" + slowest:string + "ms";
  }

  /** Content kind names (matches ContentKind enum). */
  proc contentKindName(kind: int): string {
    select kind {
      when 0 do return "PDF";
      when 1 do return "Image";
      when 2 do return "Audio";
      when 3 do return "Video";
      when 4 do return "EPUB";
      when 5 do return "GeoSpatial";
      when 6 do return "Unknown";
      otherwise do return "?";
    }
  }

  /** Get per-content-type breakdown for this locale. */
  proc contentTypeSummary(): string {
    var parts: string;
    for i in 0..6 {
      const count = contentTypeCounts[i].read();
      if count > 0 {
        if parts.size > 0 then parts += ", ";
        parts += contentKindName(i) + "=" + count:string;
      }
    }
    return if parts.size > 0 then parts else "none";
  }
}
