// Docudactyl HPC — Result Aggregator
//
// Accumulates per-locale statistics during processing, then reduces
// across all locales for a global summary report.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module ResultAggregator {
  use FFIBridge;
  use ContentType;
  use IO;
  use FileSystem;

  // ── Per-Locale Statistics ─────────────────────────────────────────────

  /** Statistics accumulated on a single locale. */
  record LocaleStats {
    var totalDocs: int = 0;
    var successDocs: int = 0;
    var failedDocs: int = 0;

    // Aggregate counts
    var totalPages: int(64) = 0;
    var totalWords: int(64) = 0;
    var totalChars: int(64) = 0;
    var totalDurationSec: real(64) = 0.0;
    var totalParseTimeMs: real(64) = 0.0;

    // Per-content-kind counters
    var pdfCount: int = 0;
    var imageCount: int = 0;
    var audioCount: int = 0;
    var videoCount: int = 0;
    var epubCount: int = 0;
    var geoCount: int = 0;
    var unknownCount: int = 0;
  }

  /** Per-locale stats storage. Each locale writes only to its own slot. */
  var perLocaleStats: [0..#numLocales] LocaleStats;

  /** Reset all per-locale stats (call at start of run). */
  proc resetStats() {
    for i in 0..#numLocales do
      perLocaleStats[i] = new LocaleStats();
  }

  /** Accumulate a single parse result into the current locale's stats. */
  proc accumulate(const ref result: ddac_parse_result_t) {
    ref stats = perLocaleStats[here.id];

    stats.totalDocs += 1;

    if result.status == 0 {
      stats.successDocs += 1;
      stats.totalPages += result.page_count: int(64);
      stats.totalWords += result.word_count;
      stats.totalChars += result.char_count;
      stats.totalDurationSec += result.duration_sec;
      stats.totalParseTimeMs += result.parse_time_ms;

      // Count by content kind
      select result.content_kind {
        when 0 do stats.pdfCount += 1;
        when 1 do stats.imageCount += 1;
        when 2 do stats.audioCount += 1;
        when 3 do stats.videoCount += 1;
        when 4 do stats.epubCount += 1;
        when 5 do stats.geoCount += 1;
        otherwise do stats.unknownCount += 1;
      }
    } else {
      stats.failedDocs += 1;
    }
  }

  // ── Global Statistics ─────────────────────────────────────────────────

  /** Global statistics reduced from all locales. */
  record GlobalStats {
    var totalDocs: int = 0;
    var successDocs: int = 0;
    var failedDocs: int = 0;
    var totalPages: int(64) = 0;
    var totalWords: int(64) = 0;
    var totalChars: int(64) = 0;
    var totalDurationSec: real(64) = 0.0;
    var totalParseTimeMs: real(64) = 0.0;
    var wallClockSec: real(64) = 0.0;

    // Per-content-kind
    var pdfCount: int = 0;
    var imageCount: int = 0;
    var audioCount: int = 0;
    var videoCount: int = 0;
    var epubCount: int = 0;
    var geoCount: int = 0;
    var unknownCount: int = 0;
  }

  /** Reduce per-locale stats into a single GlobalStats. */
  proc computeGlobal(wallClockSec: real): GlobalStats {
    var g = new GlobalStats();
    g.wallClockSec = wallClockSec;

    for i in 0..#numLocales {
      const ref s = perLocaleStats[i];
      g.totalDocs += s.totalDocs;
      g.successDocs += s.successDocs;
      g.failedDocs += s.failedDocs;
      g.totalPages += s.totalPages;
      g.totalWords += s.totalWords;
      g.totalChars += s.totalChars;
      g.totalDurationSec += s.totalDurationSec;
      g.totalParseTimeMs += s.totalParseTimeMs;
      g.pdfCount += s.pdfCount;
      g.imageCount += s.imageCount;
      g.audioCount += s.audioCount;
      g.videoCount += s.videoCount;
      g.epubCount += s.epubCount;
      g.geoCount += s.geoCount;
      g.unknownCount += s.unknownCount;
    }

    return g;
  }

  // ── Reporting ─────────────────────────────────────────────────────────

  /** Print a human-readable report to stdout. */
  proc printReport(const ref g: GlobalStats) {
    writeln();
    writeln("═══════════════════════════════════════════════════════════");
    writeln("  Docudactyl HPC — Run Report");
    writeln("═══════════════════════════════════════════════════════════");
    writeln();
    writeln("  Locales:       ", numLocales);
    writeln("  Wall clock:    ", g.wallClockSec:string, " s");
    writeln("  Throughput:    ",
            if g.wallClockSec > 0 then (g.totalDocs:real / g.wallClockSec):string
            else "N/A",
            " docs/s");
    writeln();
    writeln("  Documents:     ", g.totalDocs);
    writeln("    Succeeded:   ", g.successDocs);
    writeln("    Failed:      ", g.failedDocs);
    writeln("    Failure %:   ",
            if g.totalDocs > 0 then ((g.failedDocs:real / g.totalDocs:real) * 100.0):string
            else "0.0",
            "%");
    writeln();
    writeln("  Content Breakdown:");
    writeln("    PDF:         ", g.pdfCount);
    writeln("    Image:       ", g.imageCount);
    writeln("    Audio:       ", g.audioCount);
    writeln("    Video:       ", g.videoCount);
    writeln("    EPUB:        ", g.epubCount);
    writeln("    GeoSpatial:  ", g.geoCount);
    writeln("    Unknown:     ", g.unknownCount);
    writeln();
    writeln("  Extracted:");
    writeln("    Pages:       ", g.totalPages);
    writeln("    Words:       ", g.totalWords);
    writeln("    Characters:  ", g.totalChars);
    writeln("    A/V Duration:", g.totalDurationSec:string, " s");
    writeln();
    writeln("  Parse time:    ", g.totalParseTimeMs:string, " ms (cumulative)");
    writeln("═══════════════════════════════════════════════════════════");
    writeln();
  }

  /** Write a machine-readable Scheme report to a file. */
  proc writeReport(const ref g: GlobalStats, path: string) {
    try {
      var f = open(path, ioMode.cw);
      var w = f.writer(locking=false);

      w.writeln(";; Docudactyl HPC Run Report");
      w.writeln(";; SPDX-License-Identifier: PMPL-1.0-or-later");
      w.writeln("(run-report");
      w.writeln("  (metadata");
      w.writeln("    (generator \"docudactyl-hpc\")");
      w.writeln("    (locales ", numLocales, ")");
      w.writeln("    (wall-clock-sec ", g.wallClockSec, "))");
      w.writeln("  (summary");
      w.writeln("    (total-docs ", g.totalDocs, ")");
      w.writeln("    (succeeded ", g.successDocs, ")");
      w.writeln("    (failed ", g.failedDocs, ")");
      w.writeln("    (throughput-docs-per-sec ",
                if g.wallClockSec > 0 then g.totalDocs:real / g.wallClockSec else 0.0,
                "))");
      w.writeln("  (content-breakdown");
      w.writeln("    (pdf ", g.pdfCount, ")");
      w.writeln("    (image ", g.imageCount, ")");
      w.writeln("    (audio ", g.audioCount, ")");
      w.writeln("    (video ", g.videoCount, ")");
      w.writeln("    (epub ", g.epubCount, ")");
      w.writeln("    (geospatial ", g.geoCount, ")");
      w.writeln("    (unknown ", g.unknownCount, "))");
      w.writeln("  (extracted");
      w.writeln("    (pages ", g.totalPages, ")");
      w.writeln("    (words ", g.totalWords, ")");
      w.writeln("    (characters ", g.totalChars, ")");
      w.writeln("    (av-duration-sec ", g.totalDurationSec, "))");
      w.writeln("  (timing");
      w.writeln("    (cumulative-parse-ms ", g.totalParseTimeMs, ")))");

      w.close();
      f.close();
      writeln("[report] Written to ", path);
    } catch e: Error {
      writeln("[report] ERROR: Could not write report to ", path, ": ", e.message());
    }
  }
}
