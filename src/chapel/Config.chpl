// Docudactyl HPC — Runtime Configuration
//
// All `config const` values are tunable at launch without recompilation:
//   ./docudactyl-hpc --manifestPath=paths.txt --chunkSize=512 -nl 64
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module Config {

  // ── Manifest & I/O ──────────────────────────────────────────────────

  /** Path to the manifest file (one document path per line). */
  config const manifestPath: string = "manifest.txt";

  /** Directory for sharded output (per-locale subdirectories). */
  config const outputDir: string = "output";

  /** Output format: "scheme" (S-expressions), "json", or "csv". */
  config const outputFormat: string = "scheme";

  // ── Parallelism Tuning ──────────────────────────────────────────────

  /** Number of documents per dynamic-iteration chunk.
      Larger = less overhead, smaller = better load balance.
      256 is a good default for mixed-size corpora. */
  config const chunkSize: int = 256;

  /** Minimum chunk size for dynamic iteration.
      Prevents degenerate single-doc chunks at tail. */
  config const minChunkSize: int = 16;

  // ── Fault Tolerance ─────────────────────────────────────────────────

  /** Maximum retries per document before marking as failed. */
  config const maxRetriesPerDoc: int = 2;

  /** If the failure rate exceeds this percentage (after 1000+ samples),
      abort the run — something is systematically wrong. */
  config const failureThresholdPct: real = 5.0;

  // ── Monitoring ──────────────────────────────────────────────────────

  /** Seconds between progress reports on locale 0. */
  config const progressIntervalSec: int = 10;

  /** Timeout per document in milliseconds.
      Documents taking longer than this are abandoned.
      300000 ms = 5 minutes (generous for 1000-page manuscripts). */
  config const timeoutPerDocMs: int = 300000;

  // ── Multi-Locale / Cluster ─────────────────────────────────────────

  /** Manifest loading strategy:
        "shared"    — all locales can read the manifest file (shared filesystem)
        "broadcast" — locale 0 reads the manifest and broadcasts to all others
      Use "broadcast" on clusters without a shared filesystem. */
  config const manifestMode: string = "shared";

  // ── Result Cache (LMDB) ───────────────────────────────────────────────

  /** Directory for LMDB result cache.
      Each locale creates a subdirectory: {cacheDir}/locale-{id}/
      Set to "" (empty) to disable caching. */
  config const cacheDir: string = "";

  /** Maximum cache size per locale in MB (default 10240 = 10 GB).
      At ~1 KB per entry, 10 GB holds ~10 million cached results. */
  config const cacheSizeMB: int = 10240;

  /** Cache mode:
        "off"       - no caching (equivalent to empty cacheDir)
        "read"      - read from cache but don't store new results
        "write"     - store results but don't read (rebuild cache)
        "readwrite" - full caching (default when cacheDir is set) */
  config const cacheMode: string = "readwrite";

  // ── Processing Stages ────────────────────────────────────────────────

  /** Processing stages bitmask (string parsed to uint(64)).
      Presets: "none", "fast", "analysis", "all"
      Or comma-separated stage names:
        "language,readability,keywords,premis"
      Or a raw numeric bitmask:
        "0x7FF" (hex) or "2047" (decimal) */
  config const stagesConfig: string = "none";

  // ── Output Format Codes (for FFI) ──────────────────────────────────

  /** Map string format name to integer code for Zig FFI. */
  proc outputFormatCode(): int {
    select outputFormat {
      when "scheme" do return 0;
      when "json"   do return 1;
      when "csv"    do return 2;
      otherwise     do return 0; // default to scheme
    }
  }

  // ── Stage Bitmask Constants ─────────────────────────────────────────
  // These must match ffi/zig/src/stages.zig and generated/abi/docudactyl_ffi.h

  param STAGE_NONE: uint(64)              = 0;
  param STAGE_LANGUAGE_DETECT: uint(64)   = 1 << 0;
  param STAGE_READABILITY: uint(64)       = 1 << 1;
  param STAGE_KEYWORDS: uint(64)          = 1 << 2;
  param STAGE_CITATION_EXTRACT: uint(64)  = 1 << 3;
  param STAGE_OCR_CONFIDENCE: uint(64)    = 1 << 4;
  param STAGE_PERCEPTUAL_HASH: uint(64)   = 1 << 5;
  param STAGE_TOC_EXTRACT: uint(64)       = 1 << 6;
  param STAGE_MULTI_LANG_OCR: uint(64)    = 1 << 7;
  param STAGE_SUBTITLE_EXTRACT: uint(64)  = 1 << 8;
  param STAGE_PREMIS_METADATA: uint(64)   = 1 << 9;
  param STAGE_MERKLE_PROOF: uint(64)      = 1 << 10;
  param STAGE_EXACT_DEDUP: uint(64)       = 1 << 11;
  param STAGE_NEAR_DEDUP: uint(64)        = 1 << 12;
  param STAGE_COORD_NORMALIZE: uint(64)   = 1 << 13;
  param STAGE_NER: uint(64)               = 1 << 14;
  param STAGE_WHISPER: uint(64)           = 1 << 15;
  param STAGE_IMAGE_CLASSIFY: uint(64)    = 1 << 16;
  param STAGE_LAYOUT_ANALYSIS: uint(64)   = 1 << 17;
  param STAGE_HANDWRITING_OCR: uint(64)   = 1 << 18;
  param STAGE_FORMAT_CONVERT: uint(64)    = 1 << 19;

  param STAGE_ALL: uint(64) = (1: uint(64) << 20) - 1;

  param STAGE_FAST: uint(64) = STAGE_LANGUAGE_DETECT | STAGE_READABILITY |
      STAGE_KEYWORDS | STAGE_EXACT_DEDUP | STAGE_PREMIS_METADATA |
      STAGE_MERKLE_PROOF | STAGE_CITATION_EXTRACT;

  param STAGE_ANALYSIS: uint(64) = STAGE_FAST | STAGE_OCR_CONFIDENCE |
      STAGE_PERCEPTUAL_HASH | STAGE_TOC_EXTRACT | STAGE_NEAR_DEDUP |
      STAGE_COORD_NORMALIZE | STAGE_SUBTITLE_EXTRACT;

  /** Parse the stagesConfig string into a bitmask. */
  proc parseStagesMask(): uint(64) {
    select stagesConfig {
      when "none"     do return STAGE_NONE;
      when "fast"     do return STAGE_FAST;
      when "analysis" do return STAGE_ANALYSIS;
      when "all"      do return STAGE_ALL;
      otherwise {
        // Try hex: "0x..."
        if stagesConfig.startsWith("0x") || stagesConfig.startsWith("0X") {
          try {
            return stagesConfig[2..]: uint(64);
          } catch {
            // fall through to name parsing
          }
        }
        // Try decimal
        try {
          return stagesConfig: uint(64);
        } catch {
          // Parse comma-separated stage names
        }
        // Comma-separated names
        var mask: uint(64) = 0;
        for name in stagesConfig.split(",") {
          const trimmed = name.strip();
          select trimmed {
            when "language"    do mask |= STAGE_LANGUAGE_DETECT;
            when "readability" do mask |= STAGE_READABILITY;
            when "keywords"    do mask |= STAGE_KEYWORDS;
            when "citations"   do mask |= STAGE_CITATION_EXTRACT;
            when "ocr_confidence" do mask |= STAGE_OCR_CONFIDENCE;
            when "perceptual_hash" do mask |= STAGE_PERCEPTUAL_HASH;
            when "toc"         do mask |= STAGE_TOC_EXTRACT;
            when "multi_lang_ocr" do mask |= STAGE_MULTI_LANG_OCR;
            when "subtitles"   do mask |= STAGE_SUBTITLE_EXTRACT;
            when "premis"      do mask |= STAGE_PREMIS_METADATA;
            when "merkle"      do mask |= STAGE_MERKLE_PROOF;
            when "exact_dedup" do mask |= STAGE_EXACT_DEDUP;
            when "near_dedup"  do mask |= STAGE_NEAR_DEDUP;
            when "coordinates" do mask |= STAGE_COORD_NORMALIZE;
            when "ner"         do mask |= STAGE_NER;
            when "whisper"     do mask |= STAGE_WHISPER;
            when "image_classify" do mask |= STAGE_IMAGE_CLASSIFY;
            when "layout"      do mask |= STAGE_LAYOUT_ANALYSIS;
            when "handwriting" do mask |= STAGE_HANDWRITING_OCR;
            when "convert"     do mask |= STAGE_FORMAT_CONVERT;
            otherwise {
              writeln("[warn] Unknown stage: '", trimmed, "' — skipping");
            }
          }
        }
        return mask;
      }
    }
  }
}
