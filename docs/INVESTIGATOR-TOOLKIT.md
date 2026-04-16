# Docudactyl — Investigator Toolkit

<!--
SPDX-License-Identifier: PMPL-1.0-or-later
Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

This document describes the **investigator-focused extraction modules** added
to Docudactyl for use by citizen journalists, independent researchers, and
investigative reporters working with large document releases such as the
Epstein filings, Panama/Paradise/Pandora Papers, FinCEN Files, etc.

These modules are **standalone Zig translation units** with stable C-ABI
entry points. They can be called directly from Chapel, Rust, Julia, OCaml,
Python `ctypes`, or any language that speaks the C FFI — without going
through the full HPC pipeline.

---

## Why these modules exist

The base HPC pipeline answers "what is in this document?". Investigative
journalism needs different questions:

1. **Who appears with whom, how often?** → [`entity_graph`](#entity-graph)
2. **What was hidden under black bars?** → [`redaction_recovery`](#redaction-recovery)
3. **Where did the jet actually go?** → [`flight_log`](#flight-log)
4. **Where did the witness stop answering?** → [`evasion_detect`](#evasion-detect)
5. **What does this document contain, at a glance?** → [`investigator_summary`](#investigator-summary)

Each module is **pattern-based, no ML dependency**, fast, and deterministic.

---

## Entity Graph

**File:** `ffi/zig/src/entity_graph.zig`

Builds a cross-document co-occurrence graph of capitalised personal names.
Exports to **GraphML** (Gephi, yEd, Cytoscape) and **CSV** (Excel,
LibreOffice, Maltego, Neo4j).

### C ABI

```c
typedef struct EntityGraph EntityGraph;

EntityGraph* ddac_entity_graph_new(void);
void         ddac_entity_graph_free(EntityGraph*);

int          ddac_entity_graph_add_document(EntityGraph*, const char* text, size_t len);
int          ddac_entity_graph_export_graphml(EntityGraph*, const char* path);
int          ddac_entity_graph_export_csv(EntityGraph*, const char* path);

uint32_t     ddac_entity_graph_node_count(EntityGraph*);
uint32_t     ddac_entity_graph_edge_count(EntityGraph*);
```

### Usage sketch

```chapel
// Chapel pseudocode
var g = ddac_entity_graph_new();
for doc in manifest {
  var text = readExtractedText(doc);
  ddac_entity_graph_add_document(g, text.c_str(), text.len);
}
ddac_entity_graph_export_graphml(g, "/out/entities.graphml");
ddac_entity_graph_export_csv(g,     "/out/entities.csv");
ddac_entity_graph_free(g);
```

Load `entities.graphml` in Gephi → run ForceAtlas2 → see the cluster
structure. Load `entities.csv` in any spreadsheet to sort by weight.

### Notes
- Extracts 2+ consecutive capitalised words, optionally preceded by a
  title (Mr./Mrs./Dr./Prince/Sir/…).
- Filters a conservative stopword list (weekdays, months, common
  sentence-initial words).
- Edge weight accumulates across documents — high weight indicates
  recurring co-occurrence worth examining.

---

## Redaction Recovery

**File:** `ffi/zig/src/redaction_recovery.zig`

Extends the base redaction-detection stage with **per-page density maps**
and **overlay-only text recovery**. When a PDF carries `/Redact`
annotations (black boxes) but the underlying content stream is intact,
this module extracts the text that the overlay was meant to hide.

### When it works

✅ Overlay redactions where the text stream was NOT scrubbed (common
FOIA failure mode — many Epstein-era productions exhibit this).
❌ Redactions that rasterise the page or strip the content stream.
❌ Redactions applied at scan time (pixel-level black bars).

### C ABI

```c
typedef struct {
  int      status;
  uint32_t total_pages;
  uint32_t total_redactions;
  uint32_t pages_with_redactions;
  uint32_t recoverable_pages;
  uint64_t recovered_bytes;
  PageStats pages[4096];
  char     summary[512];
} RedactionRecoveryResult;

int ddac_redaction_recovery_analyze(const char* pdf_path, RedactionRecoveryResult*);
int ddac_redaction_recovery_dump_text(const char* pdf_path, const char* out_path);
```

### Legal & ethical note

This module extracts text that is **already present** in the document's
content stream — the same text that `cmd-A, cmd-C` in Preview would
reveal. It does not break encryption, does not OCR under pixel-level
redactions, and does not decode protected content. Use responsibly and
check your local jurisdiction's rules on reporting improperly redacted
material.

---

## Flight Log

**File:** `ffi/zig/src/flight_log.zig`

Extracts travel-document entities from text:

| Entity | Examples |
|--------|----------|
| Tail numbers | `N908JE`, `N212JE`, `G-EJES`, `D-IIKA` |
| IATA codes  | `TEB`, `PBI`, `JFK`, `STT`, `LHR`, `CDG`, `DXB` |
| ICAO codes  | `KTEB`, `KPBI`, `KJFK`, `EGLL`, `LFPB` |
| Phones      | `(212) 555-1234`, `+1 212 555 9999`, `+44 20 7946 0958` |
| Addresses   | Line-leading number + road-word heuristic |
| Manifest markers | `PAX:`, `PASSENGERS:`, `MANIFEST:`, `GUESTS:` |

### C ABI

```c
typedef struct { /* ... */ } FlightLogResult;
int ddac_flight_log_process(const char* text, size_t len, FlightLogResult*);
```

### Notes
- IATA/ICAO codes use a **whitelist** of airports of interest
  (Teterboro, Palm Beach, St. Thomas, Le Bourget, Heathrow, Dubai,
  etc.) to avoid false positives on three-letter acronyms like `CEO`
  or `FBI`. Extend the whitelist in the module source as needed.
- Tail-number pattern is liberal enough to tolerate OCR noise but
  tight enough to reject ordinary words.

---

## Evasion Detect

**File:** `ffi/zig/src/evasion_detect.zig`

Detects and categorises evasive / non-answer patterns in deposition and
interview transcripts:

| Category | Example phrase |
|----------|---------------|
| `no_recall` | "I don't recall", "I have no recollection" |
| `no_memory` | "I don't remember", "I can't remember" |
| `not_sure`  | "I'm not sure", "I couldn't say" |
| `no_knowledge` | "Not to my knowledge", "I'm not aware" |
| `would_check` | "I'd have to check", "I would need to check" |
| `asked_answered` | "Asked and answered" (lawyer interjection) |
| `fifth_amendment` | "Fifth Amendment", "on the advice of counsel" |
| `decline_answer` | "I decline to answer", "refuse to answer" |

Reports category counts, total events, and an **evasion rate** (events
per 1000 tokens, fixed-point ×1000). A rate above ~20 (i.e. `×1000 >
20000`) typically indicates a heavily evasive witness segment.

### C ABI

```c
typedef struct {
  int      status;
  uint32_t category_counts[8];
  uint32_t total_events;
  uint32_t total_tokens;
  uint32_t events_per_1k_fixed;   // rate × 1000
  char     summary[512];
} EvasionResult;

int ddac_evasion_detect(const char* text, size_t len, EvasionResult*);
```

---

## Investigator Summary

**File:** `ffi/zig/src/investigator_summary.zig`

Takes a populated `InvestigatorSummary` struct and emits an
investigator-friendly **JSON summary** per document. Designed to be
readable in a text editor and ingestible by spreadsheets, dataset
browsers, or static-site generators.

The JSON is flat and forgiving: any field may be zero/empty without
breaking consumers. A `flags` array gives quick visual triage:

```json
{
  "source_path": "/data/release_2024/doc_0042.pdf",
  "sha256": "...",
  "page_count": 184,
  "redactions": {"count": 12, "pages_affected": 4, "recoverable_pages": 2},
  "financial": {"amounts": 3, "accounts": 1},
  "legal":     {"case_citations": 5, "dockets": 2, "statutes": 1},
  "speakers":  {"count": 2, "is_deposition": true},
  "evasion":   {"total": 17, "per_1k_tokens": 12.5},
  "entities": {
    "persons":       ["Jeffrey Epstein", "Ghislaine Maxwell"],
    "tail_numbers":  ["N908JE"],
    "airports":      ["TEB", "PBI", "KTEB"],
    "phones":        ["+1 212 555 1234"],
    "addresses":     ["9 East 71st Street"]
  },
  "flags": ["has_redactions", "has_recoverable_text", "deposition", "high_evasion"]
}
```

### C ABI

```c
int ddac_investigator_summary_write(const char* out_path, const InvestigatorSummary*);
int ddac_investigator_summary_set_list_item(StringList*, uint32_t idx,
                                            const char* text, size_t len);
```

---

## Recommended Investigator Workflow

1. **Run base pipeline** (`DocudactylHPC`) to extract text + SHA + PREMIS.
2. **Per-document pass** — for each extracted text file, call:
   - `ddac_flight_log_process`     → flight / travel entities
   - `ddac_evasion_detect`         → deposition evasion stats
   - `ddac_redaction_recovery_analyze` + `_dump_text` (PDFs only)
3. **Corpus-wide pass** — accumulate entities into a single graph:
   - `ddac_entity_graph_new`
   - `ddac_entity_graph_add_document` per document
   - `ddac_entity_graph_export_graphml` + `_export_csv`
4. **Summary pass** — populate `InvestigatorSummary` from the results
   above and emit per-document JSON with
   `ddac_investigator_summary_write`.
5. **Review** — open the GraphML in Gephi, the CSV in a spreadsheet, and
   the per-document JSONs in a text editor or a static-site browser.

---

## Building & Testing

From `ffi/zig/`:

```bash
zig build              # build shared + static libraries
zig build test         # run unit tests (all new modules included)
```

All new modules have accompanying Zig unit tests. No new C dependencies
beyond Poppler + GLib (which Docudactyl already links).

---

## License

All new modules are released under **PMPL-1.0-or-later** (with MPL-2.0
fallback), matching the rest of Docudactyl.
