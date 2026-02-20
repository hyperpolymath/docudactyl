// Docudactyl HPC — Progress Reporter
//
// Background task on locale 0 that periodically prints progress:
//   [elapsed] processed/total (pct%) | rate docs/s | ETA | failures
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ProgressReporter {
  use Time;
  use Config;
  use FaultHandler;

  // ── Shared state ──────────────────────────────────────────────────────

  /** Total number of documents in this run. Set by initProgress(). */
  var totalDocs: int = 0;

  /** Atomic counter of completed documents (success + failure). */
  var completedDocs: atomic int;

  /** Flag to signal the report loop to stop. */
  var reporterDone: atomic bool;

  // ── API ───────────────────────────────────────────────────────────────

  /** Initialise the progress reporter.
      Call once before starting the forall loop. */
  proc initProgress(total: int) {
    totalDocs = total;
    completedDocs.write(0);
    reporterDone.write(false);
  }

  /** Record that one document has been processed (success or failure).
      Call from inside the forall loop after safeParse returns. */
  proc recordCompletion() {
    completedDocs.add(1);
  }

  /** Signal the reporter loop to stop.
      Call after the forall loop completes. */
  proc stopReporter() {
    reporterDone.write(true);
  }

  /** Background reporting loop. Run with `begin reportLoop(timer)`.
      Prints a status line every progressIntervalSec seconds. */
  proc reportLoop(ref timer: stopwatch) {
    while !reporterDone.read() {
      sleep(progressIntervalSec: real);

      const done = completedDocs.read();
      const elapsed = timer.elapsed();

      if done == 0 || elapsed < 0.1 then continue;

      const pct = (done: real / totalDocs: real) * 100.0;
      const rate = done: real / elapsed;
      const remaining = totalDocs - done;
      const eta = if rate > 0.0 then remaining: real / rate else 0.0;
      const failures = localeFailureCount.read();

      writeln("[", elapsed:string, "s] ",
              done, "/", totalDocs, " (", pct:string, "%) | ",
              rate:string, " docs/s | ETA ", eta:string, "s | ",
              failures, " failures");

      // Check for abort condition
      if shouldAbort() {
        writeln("[ABORT] Failure rate exceeds ", failureThresholdPct, "% — stopping run");
        reporterDone.write(true);
        return;
      }
    }

    // Final report
    const done = completedDocs.read();
    const elapsed = timer.elapsed();
    const pct = if totalDocs > 0 then (done: real / totalDocs: real) * 100.0 else 100.0;
    const rate = if elapsed > 0.0 then done: real / elapsed else 0.0;
    writeln("[DONE ] ", done, "/", totalDocs, " (", pct:string, "%) in ",
            elapsed:string, "s (", rate:string, " docs/s)");
  }

  /** Format a duration in seconds to human-readable HH:MM:SS. */
  proc formatDuration(seconds: real): string {
    const totalSec = seconds: int;
    const h = totalSec / 3600;
    const m = (totalSec % 3600) / 60;
    const s = totalSec % 60;
    return h:string + "h " + m:string + "m " + s:string + "s";
  }
}
