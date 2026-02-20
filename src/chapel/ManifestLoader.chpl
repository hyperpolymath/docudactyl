// Docudactyl HPC — Manifest Loader
//
// Loads a manifest file (one document path per line) and distributes
// paths across locales using block distribution. Supports 170M+ entries.
//
// Two loading strategies:
//   "shared"    — all locales read from a shared filesystem (default)
//   "broadcast" — locale 0 reads, then broadcasts to all locales
//
// Two-pass strategy (for shared mode):
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
  use Config;

  /** Load a manifest file and return a block-distributed array of paths.
      Lines starting with '#' are treated as comments and skipped.
      Empty lines are skipped. Leading/trailing whitespace is trimmed.

      Uses manifestMode config to choose loading strategy:
        "shared"    — direct read from shared filesystem (all locales)
        "broadcast" — locale 0 reads, broadcasts to others */
  proc loadManifest(manifestPath: string) throws {
    if manifestMode == "broadcast" then
      return loadManifestBroadcast(manifestPath);
    else
      return loadManifestShared(manifestPath);
  }

  // ══════════════════════════════════════════════════════════════════════
  // Shared filesystem mode (default)
  // ══════════════════════════════════════════════════════════════════════

  /** Load manifest assuming all locales share a filesystem. */
  proc loadManifestShared(manifestPath: string) throws {
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

    var actualCount = 0;
    {
      var f = open(manifestPath, ioMode.r);
      var reader = f.reader(locking=false);
      var line: string;
      var idx = 0;
      while reader.readLine(line) {
        const trimmed = line.strip();
        if trimmed.size > 0 && !trimmed.startsWith("#") {
          if idx < lineCount {
            docPaths[idx] = trimmed;
            idx += 1;
          }
        }
      }
      actualCount = idx;
    }

    // If actual count differs from pass-1 count, use the smaller value
    if actualCount < lineCount {
      writeln("[manifest] Note: ", lineCount - actualCount,
              " fewer paths read in pass 2 (", actualCount, " vs ", lineCount,
              "); using ", actualCount, " paths");
      const fixedDom = {0..#actualCount} dmapped new blockDist({0..#actualCount});
      var fixedPaths: [fixedDom] string;
      forall i in fixedDom do fixedPaths[i] = docPaths[i];
      validateSample(fixedPaths, actualCount);
      return fixedPaths;
    }

    validateSample(docPaths, lineCount);
    return docPaths;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Broadcast mode (for clusters without shared filesystem)
  // ══════════════════════════════════════════════════════════════════════

  /** Load manifest on locale 0, then broadcast to all locales.
      This avoids requiring a shared filesystem — only locale 0 needs
      access to the manifest file. Paths are read into a local array
      on locale 0 then copied to a block-distributed array. */
  proc loadManifestBroadcast(manifestPath: string) throws {
    var lineCount = 0;
    var localPaths: [0..0] string; // placeholder, will be resized on locale 0

    // ── Locale 0 reads the entire manifest ──────────────────────────
    on Locales[0] {
      if !exists(manifestPath) then
        throw new Error("Manifest file not found on locale 0: " + manifestPath);

      // Pass 1: count
      var count = 0;
      {
        var f = open(manifestPath, ioMode.r);
        var reader = f.reader(locking=false);
        var line: string;
        while reader.readLine(line) {
          const trimmed = line.strip();
          if trimmed.size > 0 && !trimmed.startsWith("#") then
            count += 1;
        }
      }

      if count == 0 then
        throw new Error("Manifest is empty (no valid paths): " + manifestPath);

      writeln("[manifest] ", count, " paths found in ", manifestPath,
              " (broadcast mode, reading on locale 0)");

      lineCount = count;

      // Pass 2: read into local array
      var paths: [0..#count] string;
      {
        var f = open(manifestPath, ioMode.r);
        var reader = f.reader(locking=false);
        var line: string;
        var idx = 0;
        while reader.readLine(line) {
          const trimmed = line.strip();
          if trimmed.size > 0 && !trimmed.startsWith("#") {
            if idx < count {
              paths[idx] = trimmed;
              idx += 1;
            }
          }
        }
        lineCount = idx; // actual count (may differ from pass 1)
      }
      localPaths = paths[0..#lineCount];
    }

    // ── Distribute from locale 0 to all locales ─────────────────────
    const pathDom = {0..#lineCount} dmapped new blockDist({0..#lineCount});
    var docPaths: [pathDom] string;

    // Copy from locale 0's local array to the distributed array.
    // Chapel handles the communication transparently.
    forall i in pathDom do docPaths[i] = localPaths[i];

    writeln("[manifest] Broadcast complete: ", lineCount,
            " paths distributed across ", numLocales, " locales");

    validateSample(docPaths, lineCount);
    return docPaths;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Validation
  // ══════════════════════════════════════════════════════════════════════

  /** Sample 0.1% of paths for existence (sanity check on locale 0). */
  proc validateSample(const ref paths, count: int) throws {
    const sampleSize = max(1, count / 1000);
    var rng = new randomStream(int);
    var existCount = 0;
    var checkCount = 0;

    for i in 0..#sampleSize {
      const idx = rng.next(0, count - 1);
      if exists(paths[idx]) then
        existCount += 1;
      checkCount += 1;
    }

    const existPct = if checkCount > 0 then (existCount: real / checkCount: real) * 100.0 else 0.0;
    writeln("[manifest] Validation sample: ", checkCount, " checked, ",
            existPct:string, "% exist on locale 0");

    if existPct < 50.0 then
      writeln("[manifest] WARNING: <50% of sampled paths exist — check manifest correctness");
  }

  /** Return the total number of documents in the manifest array. */
  proc manifestSize(const ref docPaths): int {
    return docPaths.size;
  }
}
