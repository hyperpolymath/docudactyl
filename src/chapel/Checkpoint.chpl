// Docudactyl HPC — Checkpoint & Resume
//
// Enables resuming long-running HPC jobs after node failures.
// Writes a checkpoint file every N documents (per locale) recording
// the last successfully processed index. On restart with --resume,
// the engine skips already-processed documents.
//
// Checkpoint file: outputDir/checkpoint-{localeId}.txt
// Format: one index per line (processed document indices)
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module Checkpoint {
  use IO;
  use FileSystem;
  use Config;
  use Set;

  /** How often to flush the checkpoint file (every N documents). */
  config const checkpointIntervalDocs: int = 1000;

  /** Whether to resume from a previous checkpoint. */
  config const resume: bool = false;

  /** Per-locale set of already-processed indices (populated on resume). */
  var completedIndices: [0..#numLocales] set(int);

  /** Per-locale counter for checkpoint flushing. */
  var docsSinceCheckpoint: [0..#numLocales] int;

  /** Checkpoint file path for a locale. */
  proc checkpointPath(localeId: int): string {
    return outputDir + "/checkpoint-" + localeId:string + ".txt";
  }

  /** Load checkpoint from a previous run, if --resume is set.
      Returns true if checkpoint was loaded. */
  proc loadCheckpoint(): bool throws {
    if !resume then return false;

    var totalLoaded = 0;

    for locId in 0..#numLocales {
      const path = checkpointPath(locId);
      if !exists(path) then continue;

      var f = open(path, ioMode.r);
      var reader = f.reader(locking=false);
      var line: string;
      while reader.readLine(line) {
        const trimmed = line.strip();
        if trimmed.size > 0 {
          const idx = trimmed: int;
          completedIndices[locId].add(idx);
          totalLoaded += 1;
        }
      }
    }

    if totalLoaded > 0 then
      writeln("[checkpoint] Resumed: ", totalLoaded, " documents already processed");

    return totalLoaded > 0;
  }

  /** Check if a document index was already processed (for resume). */
  proc isAlreadyProcessed(idx: int): bool {
    if !resume then return false;
    // Check all locales' completed sets (document could have been
    // processed on any locale in the previous run)
    for locId in 0..#numLocales {
      if completedIndices[locId].contains(idx) then return true;
    }
    return false;
  }

  /** Record that a document was successfully processed.
      Flushes to disk every checkpointIntervalDocs documents. */
  proc recordCheckpoint(idx: int) throws {
    const locId = here.id;
    completedIndices[locId].add(idx);
    docsSinceCheckpoint[locId] += 1;

    if docsSinceCheckpoint[locId] >= checkpointIntervalDocs {
      flushCheckpoint(locId);
      docsSinceCheckpoint[locId] = 0;
    }
  }

  /** Flush all pending checkpoints for a locale to disk. */
  proc flushCheckpoint(localeId: int) throws {
    const path = checkpointPath(localeId);
    var f = open(path, ioMode.cw);
    var w = f.writer(locking=false);

    for idx in completedIndices[localeId] {
      w.writeln(idx);
    }

    w.close();
    f.close();
  }

  /** Flush all locales' checkpoints (call at end of run). */
  proc flushAllCheckpoints() throws {
    for locId in 0..#numLocales {
      if completedIndices[locId].size > 0 then
        flushCheckpoint(locId);
    }
    writeln("[checkpoint] Saved progress for all locales");
  }

  /** Remove checkpoint files (call after successful completion). */
  proc clearCheckpoints() throws {
    for locId in 0..#numLocales {
      const path = checkpointPath(locId);
      if exists(path) then
        remove(path);
    }
  }
}
