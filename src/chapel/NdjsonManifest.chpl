// Docudactyl HPC — NDJSON Manifest & Streaming Output
//
// Enriched manifest format (one JSON object per line):
//   {"path":"/data/book.pdf","size":12345,"mtime":1708000000,"kind":"pdf"}
//
// Benefits over plain text manifests:
//   - Eliminates 170M stat() calls (pre-computed size/mtime)
//   - Content kind is pre-detected (no magic-byte sniffing at parse time)
//   - Enables smarter scheduling (sort by size for load balancing)
//   - Cache lookups use embedded mtime/size directly
//
// Streaming output format (one JSON result per line, appended):
//   {"path":"...","status":0,"pages":42,"words":15000,"time_ms":123.4}
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

module NdjsonManifest {
  use IO;
  use CTypes;
  use FFIBridge;

  // ══════════════════════════════════════════════════════════════════════
  // Document Entry — carries manifest metadata through the pipeline
  // ══════════════════════════════════════════════════════════════════════

  /** A document entry with optional pre-computed metadata.
      Plain manifests populate only `path`; NDJSON manifests populate all fields. */
  record DocEntry {
    /** Absolute filesystem path to the document. */
    var path: string;

    /** Pre-computed file size in bytes, or -1 if unknown (plain manifest). */
    var size: int(64) = -1;

    /** Pre-computed mtime (Unix seconds), or -1 if unknown. */
    var mtime: int(64) = -1;

    /** Pre-detected content kind string: "pdf","image","audio","video","epub","geo","unknown"
        Empty string if not pre-detected (plain manifest). */
    var kind: string = "";
  }

  /** Check whether this entry has pre-computed metadata. */
  proc DocEntry.hasMetadata(): bool {
    return this.size >= 0 && this.mtime >= 0;
  }

  // ══════════════════════════════════════════════════════════════════════
  // NDJSON Line Parser (minimal, no external JSON library)
  // ══════════════════════════════════════════════════════════════════════

  /** Parse a single NDJSON line into a DocEntry.
      Expected format: {"path":"...","size":N,"mtime":N,"kind":"..."}
      Fields beyond `path` are optional.
      Returns a DocEntry, or one with empty path if the line is invalid. */
  proc parseNdjsonLine(line: string): DocEntry {
    var entry: DocEntry;

    // Extract "path" field (required)
    entry.path = extractStringField(line, "path");
    if entry.path == "" then return entry;

    // Extract optional numeric fields
    entry.size = extractIntField(line, "size");
    entry.mtime = extractIntField(line, "mtime");
    entry.kind = extractStringField(line, "kind");

    return entry;
  }

  /** Extract a string value for a given key from a JSON line.
      Finds "key":"value" and returns value. Returns "" if not found. */
  private proc extractStringField(line: string, key: string): string {
    const needle = '"' + key + '":"';
    const pos = line.find(needle);
    if pos == -1 then return "";

    const valStart = pos + needle.size;
    if valStart >= line.size then return "";

    // Find closing quote (handle escaped quotes minimally)
    var valEnd = valStart;
    while valEnd < line.size {
      if line[valEnd] == '"' && (valEnd == valStart || line[valEnd - 1] != '\\') then
        break;
      valEnd += 1;
    }

    if valEnd > valStart then
      return line[valStart..#(valEnd - valStart)];
    else
      return "";
  }

  /** Extract an integer value for a given key from a JSON line.
      Finds "key":N and returns N. Returns -1 if not found. */
  private proc extractIntField(line: string, key: string): int(64) {
    const needle = '"' + key + '":';
    const pos = line.find(needle);
    if pos == -1 then return -1;

    const valStart = pos + needle.size;
    if valStart >= line.size then return -1;

    // Read digits (and optional leading minus)
    var numStr = "";
    var i = valStart;
    if i < line.size && line[i] == '-' {
      numStr += "-";
      i += 1;
    }
    while i < line.size && line[i] >= '0' && line[i] <= '9' {
      numStr += line[i];
      i += 1;
    }

    if numStr.size == 0 || numStr == "-" then return -1;

    try {
      return numStr: int(64);
    } catch {
      return -1;
    }
  }

  /** Detect whether a manifest file is NDJSON (first non-comment line starts with '{').
      Returns true for NDJSON, false for plain text. */
  proc detectNdjsonManifest(manifestPath: string): bool {
    try {
      var f = open(manifestPath, ioMode.r);
      var reader = f.reader(locking=false);
      var line: string;
      while reader.readLine(line) {
        const trimmed = line.strip();
        if trimmed.size > 0 && !trimmed.startsWith("#") {
          return trimmed.startsWith("{");
        }
      }
    } catch {
      return false;
    }
    return false;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Streaming NDJSON Output Writer
  // ══════════════════════════════════════════════════════════════════════

  /** Per-locale streaming NDJSON output writer.
      Appends one JSON line per processed document to:
        {outputDir}/shard-{localeId}/results.ndjson */
  record NdjsonWriter {
    var ch: fileWriter(locking=true);
    var active: bool = false;

    /** Write a single result line.
        Fields match ddac_parse_result_t but in JSON for interoperability. */
    proc ref writeResult(inputPath: string, const ref result: ddac_parse_result_t,
                         parseTimeMs: real) {
      if !active then return;

      // Build JSON line manually (no external JSON library)
      var line = '{"path":' + jsonEscapeString(inputPath);
      line += ',"status":' + result.status:string;
      line += ',"content_kind":' + result.content_kind:string;
      line += ',"pages":' + result.page_count:string;
      line += ',"words":' + result.word_count:string;
      line += ',"chars":' + result.char_count:string;

      if result.duration_sec > 0.0 then
        line += ',"duration_sec":' + result.duration_sec:string;

      line += ',"parse_time_ms":' + parseTimeMs:string;

      // Include SHA-256 if present
      const sha = string.createCopyingBuffer(result.sha256: c_ptrConst(c_char));
      if sha.size > 0 then
        line += ',"sha256":' + jsonEscapeString(sha);

      // Include title if present
      const title = string.createCopyingBuffer(result.title: c_ptrConst(c_char));
      if title.size > 0 then
        line += ',"title":' + jsonEscapeString(title);

      line += "}";

      try {
        ch.writeln(line);
      } catch {
        // Silently drop — don't interrupt the pipeline
      }
    }

    /** Flush buffered output. */
    proc ref flush() {
      if active {
        try { ch.flush(); } catch { }
      }
    }
  }

  /** Create a streaming NDJSON writer for the current locale. */
  proc initNdjsonWriter(shardPath: string): NdjsonWriter {
    const ndjsonPath = shardPath + "/results.ndjson";
    try {
      var f = open(ndjsonPath, ioMode.cw);
      var writer = f.writer(locking=true);
      return new NdjsonWriter(ch=writer, active=true);
    } catch {
      writeln("[warn] Cannot open NDJSON output: ", ndjsonPath);
      var dummy: NdjsonWriter;
      return dummy;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // JSON Helpers
  // ══════════════════════════════════════════════════════════════════════

  /** Escape a string for JSON (handles quotes and backslashes). */
  private proc jsonEscapeString(s: string): string {
    var result = '"';
    for ch in s {
      select ch {
        when '"'  do result += '\\"';
        when '\\' do result += '\\\\';
        when '\n' do result += '\\n';
        when '\r' do result += '\\r';
        when '\t' do result += '\\t';
        otherwise do result += ch;
      }
    }
    result += '"';
    return result;
  }
}
