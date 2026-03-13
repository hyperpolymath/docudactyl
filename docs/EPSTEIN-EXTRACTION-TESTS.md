# Epstein Files — Docudactyl Extraction Tests & Benchmarks
#
# SPDX-License-Identifier: PMPL-1.0-or-later
# Author: Jonathan D.A. Jewell
# Created: 2026-03-13
#
# Extracted from the master pathway: bofig/docs/EPSTEIN-FILES-WORK-PATHWAY.md
# This file contains only the Docudactyl-specific phases (1.1–1.7).

## Dataset Characteristics

| Attribute | Value |
|-----------|-------|
| Total files | ~3,200,000 |
| Total size | ~218 GB |
| Data sets | 12 (flight logs, court filings, depositions, financial records, photos, communications, ...) |
| Named entities (est.) | 23,000+ unique persons, orgs, locations |
| Primary format | Scanned PDF (96 DPI, many poor quality) |
| Secondary formats | TIFF, JPEG, DOCX, XLS, email (EML/PST) |
| Redaction style | Overlay-only (text stream often intact) |
| Financial transactions (est.) | 16,000+ |
| Languages | English (primary), French, some Spanish |
| Time span | 1990s–2024 |

---

## Phase 1: Docudactyl Extraction Pipeline (Weeks 1–6)

### Step 1.1: Core OCR + Text Extraction (DONE — existing stages 0-8)

Already implemented in `stages.zig`:
- Language detection, readability, keywords, citations
- OCR confidence, perceptual hash, TOC extraction
- Multi-language OCR, subtitle extraction

**Tests:**
- [x] Unit test: each stage function with known input produces expected Cap'n Proto output
- [x] Integration test: 10-document mini-corpus end-to-end
- [ ] Benchmark: single-node throughput for scanned PDFs (target: 2 docs/sec on 8-core)

### Step 1.2: Redaction Detection (DONE — bit 20, `stageRedactionDetect`)

Scans Poppler annotations for Type 12 (POPPLER_ANNOT_REDACT), checks if
text is extractable under overlay-only redactions.

**Tests:**
- [ ] T-RED-1: Synthetic PDF with 5 /Redact annotations → count=5, status="redacted"
- [ ] T-RED-2: PDF with black fill rectangles but no /Redact annots → status="clean" (future: heuristic upgrade)
- [ ] T-RED-3: PDF with overlay redaction + recoverable text → recoverable_count > 0
- [ ] T-RED-4: Non-PDF input (JPEG) → status="not_applicable"
- [ ] T-RED-5: Corrupt/unreadable PDF → status="error"

**Benchmarks:**
- [ ] B-RED-1: 1000 PDFs (mixed redacted/clean) — target: <500ms per document
- [ ] B-RED-2: Memory usage during annotation scan — target: <50MB peak per document

### Step 1.3: Financial Entity Extraction (DONE — bit 21, `stageFinancialExtract`)

Pattern-based detection of currency symbols ($, £, €), ISO codes (USD, GBP, EUR, CHF, JPY, CAD),
account-like digit sequences (8-20 digits).

**Tests:**
- [ ] T-FIN-1: Text "$1,234.56 paid to account 12345678" → amounts=1, accounts=1
- [ ] T-FIN-2: Text "USD 50,000 transferred" → amounts=1
- [ ] T-FIN-3: Text "£2.3 million to HSBC account 1234-5678-9012" → amounts=1, accounts=1
- [ ] T-FIN-4: Phone numbers should NOT match as accounts (7-digit filter)
- [ ] T-FIN-5: Empty text → status="none_found", amounts=0, accounts=0
- [ ] T-FIN-6: Mixed currencies in single document → correct total count

**Benchmarks:**
- [ ] B-FIN-1: 10MB text document scan — target: <200ms
- [ ] B-FIN-2: Accuracy on annotated Epstein financial records sample (50 docs) — target: >80% recall

### Step 1.4: Legal NER (DONE — bit 22, `stageLegalNer`)

Pattern-based detection of case citations ("v."), docket numbers ("No.", "Case"),
statute references ("U.S.C.", "§").

**Tests:**
- [ ] T-LEG-1: "Doe v. Epstein" → case_citations=1
- [ ] T-LEG-2: "No. 08-cv-1234" → docket_refs=1
- [ ] T-LEG-3: "18 U.S.C. § 1591" → statute_refs=1 (both U.S.C. and § counted)
- [ ] T-LEG-4: "vs." variant → case_citations=1
- [ ] T-LEG-5: Real Epstein court filing excerpt → realistic counts
- [ ] T-LEG-6: Non-legal document (flight log) → all counts = 0

**Benchmarks:**
- [ ] B-LEG-1: 5MB legal document — target: <150ms
- [ ] B-LEG-2: Precision on annotated legal corpus (100 docs) — target: >75%

### Step 1.5: Speaker Identification (bit 23, ML dispatch)

ML-based speaker diarization via ONNX Runtime. Dispatches to stage_id=5
(speaker_id.onnx model).

**Tests:**
- [ ] T-SPK-1: With ML handle + model → status="ok", speaker_count > 0
- [ ] T-SPK-2: Without ML handle → status="not_available"
- [ ] T-SPK-3: Non-audio input → graceful fallback
- [ ] T-SPK-4: Deposition audio with 2 speakers → speaker_count=2

**Benchmarks:**
- [ ] B-SPK-1: 30-minute deposition audio — target: <60s inference
- [ ] B-SPK-2: Memory usage during diarization — target: <2GB

### Step 1.6: STAGE_INVESTIGATIVE Preset Validation

The `STAGE_INVESTIGATIVE` preset combines all investigative stages.

**Tests:**
- [ ] T-INV-1: STAGE_INVESTIGATIVE includes bits 20-23
- [ ] T-INV-2: STAGE_ALL includes all 24 stages
- [ ] T-INV-3: runStages with STAGE_INVESTIGATIVE on a legal PDF → all 4 stages produce output
- [ ] T-INV-4: runStages with STAGE_INVESTIGATIVE on audio file → speaker ID runs, redaction skipped

### Step 1.7: Multi-Locale HPC Cluster Test (D1)

Chapel-based parallel processing on GASNet/IBV transport.

**Tests:**
- [ ] T-HPC-1: 4-node cluster processes 100 documents without error
- [ ] T-HPC-2: Load balancing: no single node processes >40% of total
- [ ] T-HPC-3: Node failure recovery: cluster continues if 1 of 4 nodes drops
- [ ] T-HPC-4: Identical results on 1-node vs 4-node runs (determinism)

**Benchmarks:**
- [ ] B-HPC-1: 10,000 scanned PDFs on 4-node cluster — target: <30 minutes
- [ ] B-HPC-2: 100,000 PDFs on 16-node cluster — target: <2 hours
- [ ] B-HPC-3: Linear scaling factor — target: >0.7x per added node
- [ ] B-HPC-4: Full Epstein corpus (3.2M files) on 256 nodes — target: <4 hours

---

## Completion Tracker (Docudactyl Phases Only)

| # | Step | Status | Tests | Benchmarks |
|---|------|--------|-------|------------|
| 1.1 | Core OCR + Text | DONE | Partial | 0/1 |
| 1.2 | Redaction Detection | DONE (code) | 0/5 | 0/2 |
| 1.3 | Financial Extraction | DONE (code) | 0/6 | 0/2 |
| 1.4 | Legal NER | DONE (code) | 0/6 | 0/2 |
| 1.5 | Speaker ID | DONE (dispatch) | 0/4 | 0/2 |
| 1.6 | Investigative Preset | DONE | 0/4 | — |
| 1.7 | HPC Cluster Test | TODO | 0/4 | 0/4 |

**Totals: 29 tests, 13 benchmarks | Current: 0 tests written, 0 benchmarks run**

## Cross-References

- **Full pipeline pathway:** `bofig/docs/EPSTEIN-FILES-WORK-PATHWAY.md`
- **Master integration plan:** `bofig/docs/INTEGRATION-PLAN.md`
- **Docudactyl integration role:** `docs/INTEGRATION-PLAN-DOCUDACTYL.md` (this repo)
