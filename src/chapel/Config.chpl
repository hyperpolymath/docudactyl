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
}
