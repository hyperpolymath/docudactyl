// Docudactyl HPC — Manifest Loader
//
// Loads a manifest file and distributes entries across locales using block
// distribution. Supports 170M+ entries in two formats:
//
//   Plain text:  one document path per line
//   NDJSON:      {"path":"/data/book.pdf","size":12345,"mtime":1708000000,"kind":"pdf"}
//
// NDJSON manifests carry pre-computed metadata (size, mtime, content kind),
// eliminating 170M stat() calls during cache lookup and enabling smarter
// scheduling.
//
// Two loading strategies:
//   "shared"    — all locales read from a shared filesystem (default)
//   "broadcast" — locale 0 reads, then broadcasts to all locales
//
// Two-pass strategy (for shared mode):
//   Pass 1: Count valid lines (skip comments, blanks)
//   Pass 2: Read entries into a block-distributed array
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ManifestLoader {
  use IO;
  use FileSystem;
  use BlockDist;
  use Random;
  use Config;
  use NdjsonManifest;

  /** Load a manifest file and return a block-distributed array of DocEntry.
      Auto-detects format (plain vs NDJSON) unless manifestFormat is set.
      Lines starting with '#' are treated as comments and skipped.
      Empty lines are skipped. Leading/trailing whitespace is trimmed.

      Uses manifestMode config to choose loading strategy:
        "shared"    — direct read from shared filesystem (all locales)
        "broadcast" — locale 0 reads, broadcasts to others */
  proc loadManifest(manifestPath: string) throws {
    // Determine format
    const isNdjson = if manifestFormat == "ndjson" then true
                     else if manifestFormat == "plain" then false
                     else detectNdjsonManifest(manifestPath);

    if isNdjson then
      writeln("[manifest] Format: NDJSON (enriched metadata)");
    else
      writeln("[manifest] Format: plain text (paths only)");

    if manifestMode == "broadcast" then
      return loadManifestBroadcast(manifestPath, isNdjson);
    else
      return loadManifestShared(manifestPath, isNdjson);
  }

  // ══════════════════════════════════════════════════════════════════════
  // Shared filesystem mode (default)
  // ══════════════════════════════════════════════════════════════════════

  /** Load manifest assuming all locales share a filesystem. */
  proc loadManifestShared(manifestPath: string, isNdjson: bool) throws {
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
      throw new Error("Manifest is empty (no valid entries): " + manifestPath);

    writeln("[manifest] ", lineCount, " entries found in ", manifestPath);

    // ── Pass 2: read into block-distributed array ───────────────────
    const entryDom = {0..#lineCount} dmapped new blockDist({0..#lineCount});
    var docEntries: [entryDom] DocEntry;

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
            if isNdjson then
              docEntries[idx] = parseNdjsonLine(trimmed);
            else
              docEntries[idx] = new DocEntry(path=trimmed);
            idx += 1;
          }
        }
      }
      actualCount = idx;
    }

    // If actual count differs from pass-1 count, use the smaller value
    if actualCount < lineCount {
      writeln("[manifest] Note: ", lineCount - actualCount,
              " fewer entries read in pass 2 (", actualCount, " vs ", lineCount,
              "); using ", actualCount, " entries");
      const fixedDom = {0..#actualCount} dmapped new blockDist({0..#actualCount});
      var fixedEntries: [fixedDom] DocEntry;
      forall i in fixedDom do fixedEntries[i] = docEntries[i];
      validateEntrySample(fixedEntries, actualCount);
      return fixedEntries;
    }

    validateEntrySample(docEntries, lineCount);

    if isNdjson {
      // Report metadata coverage
      var metaCount = 0;
      for entry in docEntries do
        if entry.hasMetadata() then metaCount += 1;
      writeln("[manifest] ", metaCount, "/", lineCount,
              " entries have pre-computed metadata (stat()-free)");
    }

    return docEntries;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Broadcast mode (for clusters without shared filesystem)
  // ══════════════════════════════════════════════════════════════════════

  /** Load manifest on locale 0, then broadcast to all locales. */
  proc loadManifestBroadcast(manifestPath: string, isNdjson: bool) throws {
    var lineCount = 0;
    var localEntries: [0..0] DocEntry;

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
        throw new Error("Manifest is empty (no valid entries): " + manifestPath);

      writeln("[manifest] ", count, " entries found in ", manifestPath,
              " (broadcast mode, reading on locale 0)");

      lineCount = count;

      // Pass 2: read into local array
      var entries: [0..#count] DocEntry;
      {
        var f = open(manifestPath, ioMode.r);
        var reader = f.reader(locking=false);
        var line: string;
        var idx = 0;
        while reader.readLine(line) {
          const trimmed = line.strip();
          if trimmed.size > 0 && !trimmed.startsWith("#") {
            if idx < count {
              if isNdjson then
                entries[idx] = parseNdjsonLine(trimmed);
              else
                entries[idx] = new DocEntry(path=trimmed);
              idx += 1;
            }
          }
        }
        lineCount = idx;
      }
      localEntries = entries[0..#lineCount];
    }

    // ── Distribute from locale 0 to all locales ─────────────────────
    const entryDom = {0..#lineCount} dmapped new blockDist({0..#lineCount});
    var docEntries: [entryDom] DocEntry;

    forall i in entryDom do docEntries[i] = localEntries[i];

    writeln("[manifest] Broadcast complete: ", lineCount,
            " entries distributed across ", numLocales, " locales");

    validateEntrySample(docEntries, lineCount);
    return docEntries;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Validation
  // ══════════════════════════════════════════════════════════════════════

  /** Sample 0.1% of entries for path existence (sanity check on locale 0). */
  proc validateEntrySample(const ref entries, count: int) throws {
    const sampleSize = max(1, count / 1000);
    var rng = new randomStream(int);
    var existCount = 0;
    var checkCount = 0;

    for i in 0..#sampleSize {
      const idx = rng.next(0, count - 1);
      if exists(entries[idx].path) then
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
  proc manifestSize(const ref docEntries): int {
    return docEntries.size;
  }
}
