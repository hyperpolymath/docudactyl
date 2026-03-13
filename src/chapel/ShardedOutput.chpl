// Docudactyl HPC — Sharded Output
//
// Per-locale output directories: output/shard-{localeId}/
// Each locale writes only to its own shard, eliminating I/O contention.
// Optional post-run merge combines all shards.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ShardedOutput {
  use FileSystem;
  use Path;
  use Config;

  // ── Shard Management ──────────────────────────────────────────────────

  /** Create output shard directories on all locales.
      Creates: outputDir/shard-0/, outputDir/shard-1/, ... */
  proc initShards() throws {
    coforall loc in Locales do on loc {
      const shardPath = shardDir(loc.id);
      if !exists(shardPath) then
        mkdir(shardPath, parents=true);
    }
    writeln("[shards] Initialised ", numLocales, " output shards in ", outputDir);
  }

  /** Return the shard directory for a given locale. */
  proc shardDir(localeId: int): string {
    return outputDir + "/shard-" + localeId:string;
  }

  /** Compute the output file path for a given input document.
      Preserves the filename, changes extension to match format,
      places in the current locale's shard directory.

      Example: /data/books/moby.pdf → output/shard-3/moby.txt */
  proc outputPathFor(inputPath: string): string {
    const base = basename(inputPath);

    // Strip original extension
    var dotPos = -1;
    for i in 0..#base.size by -1 {
      if base[i] == "." {
        dotPos = i;
        break;
      }
    }

    const stem = if dotPos > 0 then base[0..#dotPos] else base;

    // Choose extension based on output format
    var ext: string;
    select outputFormat {
      when "scheme" do ext = ".scm";
      when "json"   do ext = ".json";
      when "csv"    do ext = ".csv";
      otherwise     do ext = ".txt";
    }

    return shardDir(here.id) + "/" + stem + ext;
  }

  // ── Post-Run Merge ────────────────────────────────────────────────────

  /** Merge all shard directories into a single output directory.
      This is optional and runs after the forall loop completes.
      Only runs on locale 0 for simplicity. */
  proc mergeAllShards() throws {
    if numLocales == 1 {
      writeln("[shards] Single locale — no merge needed");
      return;
    }

    const mergedDir = outputDir + "/merged";
    if !exists(mergedDir) then
      mkdir(mergedDir, parents=true);

    var fileCount = 0;

    for locId in 0..#numLocales {
      const shard = shardDir(locId);
      if !exists(shard) then continue;

      for entry in listDir(shard) {
        const src = shard + "/" + entry;
        const dst = mergedDir + "/" + entry;

        // Handle name collisions by prefixing locale id
        const finalDst = if exists(dst)
          then mergedDir + "/shard" + locId:string + "-" + entry
          else dst;

        rename(src, finalDst);
        fileCount += 1;
      }
    }

    writeln("[shards] Merged ", fileCount, " files into ", mergedDir);
  }

  /** Count total output files across all shards. */
  proc totalOutputFiles(): int throws {
    var count = 0;
    for locId in 0..#numLocales {
      const shard = shardDir(locId);
      if exists(shard) {
        for entry in listDir(shard) {
          count += 1;
        }
      }
    }
    return count;
  }
}
