# Docudactyl Integration Plan — Pipeline Role
#
# SPDX-License-Identifier: PMPL-1.0-or-later
# Author: Jonathan D.A. Jewell
# Created: 2026-03-13
#
# Extracted from the master integration plan: bofig/docs/INTEGRATION-PLAN.md

## Docudactyl's Role in the Pipeline

Docudactyl is the **ingestion layer**. It takes raw documents and produces
structured extraction results that flow into Lithoglyph (audit-grade storage)
and then Bofig (evidence graph navigation).

```
Raw Documents (200K+ files)
  → Docudactyl   (HPC extraction: OCR, NER, metadata, classification)
    → Lithoglyph (audit-grade storage: provenance, reversibility, PROMPT)
      → Bofig    (evidence graph: claims, relationships, navigation)
```

## Docudactyl Tasks (from Integration Plan)

| # | Task | Priority | Effort | Notes |
|---|------|----------|--------|-------|
| D1 | Multi-locale HPC cluster test (GASNet/IBV, 4+ nodes) | Critical | Medium | Only v0.4.1 blocker |
| D2 | Cap'n Proto → Lithoglyph output adapter | High | Medium | New output stage that emits GQL-compatible evidence records |
| D3 | Legal document NER model | High | Medium | Docket numbers, case names, judge names, legal citations |
| D4 | Financial record extraction stage | High | Medium | Transaction amounts, dates, account identifiers, counterparties |
| D5 | Speaker identification stage (testimony/depositions) | Medium | Large | Who said what — maps to witness testimony in bofig |
| D6 | Redaction detection stage | Medium | Small | Flag redacted regions, track unredaction over time |
| D7 | British Library pilot (170M items) | Low | Large | v1.0.0 milestone |

## Output Contract

Each processed document produces:
- Extracted text (OCR'd if needed) + confidence score
- NER entities (people, orgs, locations, dates, amounts)
- SHA-256 + perceptual hash (dedup)
- Metadata (Dublin Core + format-specific)
- Auto-PROMPT scores derived from extraction quality
- Language, keywords, citations

## Integration Points Involving Docudactyl

### Integration 1: Docudactyl → Lithoglyph (D2 + L6)

```
Docudactyl Cap'n Proto output
  → Adapter (D2) serializes to GQL INSERT statements
    → Lithoglyph ingest bridge (L6) batch-imports with:
      - Auto-PROMPT scoring from extraction confidence
      - SHA-256 dedup against existing evidence
      - Actor="docudactyl-pipeline", Rationale="Batch extraction run {id}"
      - Provenance: source file path, extraction timestamp, OCR confidence
```

### Integration 3: Entity Resolution Loop (D3/D4/D5 → L5 → B1)

```
Docudactyl NER extracts raw entities
  → Lithoglyph stores with alias tracking (L5)
    → Bofig entity resolution (B1) merges aliases
    → Merge decision logged in Lithoglyph journal
    → Reversible if co-reference was incorrect
```

### Integration 4: Financial Flow Analysis (D4 → L4 → B2)

```
Docudactyl extracts transactions from bank records (D4)
  → Lithoglyph financial_transactions collection (L4)
    → Bofig GraphQL: transactionChain(entityId, depth) (B2)
```

## Phase Assignment

Docudactyl work falls primarily in **Phase A (Foundation)** and **Phase C (Investigation Features)**:

- **Phase A (Weeks 1-4):** D1 (HPC cluster test)
- **Phase B (Weeks 5-8):** D2 (Cap'n Proto adapter)
- **Phase C (Weeks 9-14):** D3, D4, D5 (NER models + speaker ID)

## Cross-References

- **Master plan:** `bofig/docs/INTEGRATION-PLAN.md`
- **Epstein worked example:** `bofig/docs/EPSTEIN-FILES-WORK-PATHWAY.md`
- **Epstein Docudactyl phases:** `docs/EPSTEIN-EXTRACTION-TESTS.md` (this repo)
