// Docudactyl HPC — Manifest Loader
//
// Loads a manifest file (one document path per line) and distributes
// paths across locales using block distribution. Supports 170M+ entries.
//
// Two-pass strategy:
//   Pass 1: Count valid lines (skip comments, blanks)
//   Pass 2: Read paths into a block-distributed array
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ManifestLoader {
  use IO;
  use FileSystem;
  use BlockDist;
  use Random;

  /** Load a manifest file and return a block-distributed array of paths.
      Lines starting with '#' are treated as comments and skipped.
      Empty lines are skipped. Leading/trailing whitespace is trimmed. */
  proc loadManifest(manifestPath: string) throws {
    if !exists(manifestPath) then
      throw new Error("Manifest file not found: " + manifestPath);

    // ── Pass 1: count valid lines ───────────────────────────────────
    var lineCount = 0;
    {
      var f = open(manifestPath, ioMode.r);
      var reader = f.reader(locking=false);
      var line: string;
      while reader.readLine(line) {
        const trimmed = line.strip();
        if trimmed.size > 0 && !trimmed.startsWith("#") then
          lineCount += 1;
      }
    }

    if lineCount == 0 then
      throw new Error("Manifest is empty (no valid paths): " + manifestPath);

    writeln("[manifest] ", lineCount, " paths found in ", manifestPath);

    // ── Pass 2: read into block-distributed array ───────────────────
    const pathDom = {0..#lineCount} dmapped new blockDist({0..#lineCount});
    var docPaths: [pathDom] string;

    {
      var f = open(manifestPath, ioMode.r);
      var reader = f.reader(locking=false);
      var line: string;
      var idx = 0;
      while reader.readLine(line) {
        const trimmed = line.strip();
        if trimmed.size > 0 && !trimmed.startsWith("#") {
          docPaths[idx] = trimmed;
          idx += 1;
        }
      }
    }

    // ── Validation: sample 0.1% of paths for existence ──────────────
    const sampleSize = max(1, lineCount / 1000);
    var rng = new randomStream(int);
    var existCount = 0;
    var checkCount = 0;

    for i in 0..#sampleSize {
      const idx = rng.next(0, lineCount - 1);
      if exists(docPaths[idx]) then
        existCount += 1;
      checkCount += 1;
    }

    const existPct = if checkCount > 0 then (existCount: real / checkCount: real) * 100.0 else 0.0;
    writeln("[manifest] Validation sample: ", checkCount, " checked, ",
            existPct:string, "% exist on locale 0");

    if existPct < 50.0 then
      writeln("[manifest] WARNING: <50% of sampled paths exist — check manifest correctness");

    return docPaths;
  }

  /** Return the total number of documents in the manifest array. */
  proc manifestSize(const ref docPaths): int {
    return docPaths.size;
  }
}
