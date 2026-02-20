# Docudactyl HPC — Stage Results Schema (Cap'n Proto)
#
# Defines the binary wire format for per-document processing stage results.
# Replaces the previous JSON .stages output with zero-copy Cap'n Proto binary.
#
# Output file: {output_path}.stages.capnp
# Root struct: StageResults (23 data words, 30 pointer words)
#
# Usage:
#   capnpc -o c schema/stages.capnp     # Generate C decoder
#   capnpc -o rust schema/stages.capnp   # Generate Rust decoder
#   capnp decode schema/stages.capnp StageResults < result.stages.capnp
#
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

@0xd4c8e2f1a3b59670;

struct StageResults {
  # ── Metadata ────────────────────────────────────────────────────────
  # Bitmask of which stages were enabled for this document.
  # Check individual bits to determine which fields contain valid data.
  # Matches DDAC_STAGE_* constants from docudactyl_ffi.h.
  stagesMask @0 :UInt64;

  # ── Language Detection (bit 0) ──────────────────────────────────────
  langScript     @1 :Text;     # Dominant script: "Latin", "CJK", "Cyrillic", "Arabic", "Devanagari"
  langLanguage   @2 :Text;     # ISO 639-1 language code: "en", "zh", "ru", "ar", "hi", "und"
  langConfidence @3 :Float64;  # Confidence 0.0-1.0

  # ── Readability (bit 1) ─────────────────────────────────────────────
  readabilityGrade     @4 :Float64;  # Flesch-Kincaid Grade Level
  readabilityEase      @5 :Float64;  # Flesch Reading Ease (0-100+)
  readabilitySentences @6 :UInt64;
  readabilityWords     @7 :UInt64;
  readabilitySyllables @8 :UInt64;

  # ── Keyword Extraction (bit 2) ──────────────────────────────────────
  keywordCount       @9  :UInt32;     # Number of top keywords returned
  keywordTotalUnique @10 :UInt32;     # Total unique words in document
  keywordWords       @11 :List(Text); # Top keywords by frequency (max 20)

  # ── Citation Extraction (bit 3) ─────────────────────────────────────
  citationTotal      @12 :UInt32;
  citationDoi        @13 :UInt32;
  citationIsbn       @14 :UInt32;
  citationUrl        @15 :UInt32;
  citationYearRef    @16 :UInt32;
  citationNumericRef @17 :UInt32;

  # ── OCR Confidence (bit 4) ──────────────────────────────────────────
  ocrMeanConfidence @18 :Int32;  # Tesseract confidence 0-100, or -1 if not applicable

  # ── Perceptual Hash (bit 5) ─────────────────────────────────────────
  perceptualAhash @19 :Text;  # 16-char hex average hash

  # ── Table of Contents (bit 6) ───────────────────────────────────────
  tocEntries @20 :List(TocEntry);

  # ── Multi-Language OCR (bit 7) ──────────────────────────────────────
  multiLangLanguages  @21 :Text;    # Tesseract language string, e.g. "eng+fra+deu"
  multiLangConfidence @22 :Int32;   # Mean confidence across all languages
  multiLangWords      @23 :UInt64;
  multiLangChars      @24 :UInt64;

  # ── Subtitle Extraction (bit 8) ─────────────────────────────────────
  subtitleStreams     @25 :List(SubtitleStream);
  subtitleStreamCount @26 :UInt32;

  # ── PREMIS Metadata (bit 9) ─────────────────────────────────────────
  premisObjectCategory  @27 :Text;   # Always "file"
  premisFormat          @28 :Text;   # MIME type
  premisSize            @29 :Int64;  # File size in bytes
  premisFixityAlgorithm @30 :Text;   # "SHA-256"
  premisFixityValue     @31 :Text;   # Hex SHA-256 digest
  premisFormatRegistry  @32 :Text;   # "PRONOM"

  # ── Merkle Proof (bit 10) ───────────────────────────────────────────
  merkleRoot      @33 :Text;    # 64-char hex root hash
  merkleDepth     @34 :UInt32;  # Tree depth
  merkleLeafCount @35 :UInt32;  # Number of 4KB leaf chunks

  # ── Exact Dedup (bit 11) ────────────────────────────────────────────
  exactDedupSha256 @36 :Text;  # 64-char hex SHA-256 for cross-document comparison

  # ── Near Dedup (bit 12) ─────────────────────────────────────────────
  nearDedupAhash  @37 :Text;  # 16-char hex perceptual hash (images only)
  nearDedupStatus @38 :Text;  # "" for success, "not_applicable" for non-images
  nearDedupReason @39 :Text;  # Why not applicable (e.g. "not an image")

  # ── Coordinate Normalization (bit 13) ───────────────────────────────
  coordCrs    @40 :Text;     # Coordinate reference system (WKT, truncated to 200 chars)
  coordMinX   @41 :Float64;
  coordMinY   @42 :Float64;
  coordMaxX   @43 :Float64;
  coordMaxY   @44 :Float64;
  coordRasterX @45 :Float64; # Raster X dimension
  coordRasterY @46 :Float64; # Raster Y dimension

  # ── ML Stubs (bits 14-19) ──────────────────────────────────────────
  # These stages require external ML runtimes not yet integrated.
  # status = "not_available", reason = human-readable explanation.
  nerStatus              @47 :Text;
  nerReason              @48 :Text;
  whisperStatus          @49 :Text;
  whisperReason          @50 :Text;
  imageClassifyStatus    @51 :Text;
  imageClassifyReason    @52 :Text;
  layoutAnalysisStatus   @53 :Text;
  layoutAnalysisReason   @54 :Text;
  handwritingOcrStatus   @55 :Text;
  handwritingOcrReason   @56 :Text;
  formatConvertStatus    @57 :Text;
  formatConvertReason    @58 :Text;

  # ── Nested Types ────────────────────────────────────────────────────

  struct TocEntry {
    title @0 :Text;
    depth @1 :UInt32;
  }

  struct SubtitleStream {
    index    @0 :UInt32;
    codec    @1 :Text;
    language @2 :Text;
  }
}
