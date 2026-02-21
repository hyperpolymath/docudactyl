;; SPDX-License-Identifier: PMPL-1.0-or-later
(ecosystem
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-21"))
  (project
    (name "docudactyl")
    (purpose "Multi-format HPC document extraction engine — British Library scale")
    (position-in-ecosystem "Core processing engine in the bofig investigative journalism toolkit"))
  (related-projects
    (project "bofig"
      (relationship parent)
      (description "Evidence Graph for Investigative Journalism — Docudactyl is its document ingestion layer"))
    (project "language-bridges"
      (relationship sibling-standard)
      (description "FFI bridges between languages via Zig — Docudactyl's Zig FFI follows the same ABI pattern"))
    (project "rsr-template-repo"
      (relationship template)
      (description "Rhodium Standard Repository template — Docudactyl's repo structure, workflows, and checkpoint protocol derive from this"))
    (project "developer-ecosystem/zig-ecosystem"
      (relationship inspiration)
      (description "Zig ecosystem conventions informing the FFI layer design"))
    (project "developer-ecosystem/idris2-ecosystem"
      (relationship inspiration)
      (description "Idris2 ecosystem conventions informing the ABI proof layer")))
  (consumers
    (consumer "bofig evidence-graph"
      (description "Consumes Docudactyl's extracted text/metadata for claim-evidence graph construction"))
    (consumer "docudactyl-scm"
      (description "OCaml offline tool that transforms Docudactyl's JSON/text output to Scheme S-expressions")))
  (dependencies
    (runtime "Chapel" (purpose "HPC distributed execution"))
    (runtime "Zig" (purpose "FFI layer, links C libraries"))
    (runtime "Poppler" (purpose "PDF text extraction"))
    (runtime "Tesseract" (purpose "OCR"))
    (runtime "FFmpeg" (purpose "Audio/video metadata"))
    (runtime "libxml2" (purpose "EPUB parsing"))
    (runtime "GDAL" (purpose "Geospatial data"))
    (runtime "libvips" (purpose "Image processing"))
    (runtime "LMDB" (purpose "Per-locale L1 cache"))
    (optional "ONNX Runtime" (purpose "ML inference — NER, Whisper, image classify, layout, handwriting"))
    (optional "PaddleOCR" (purpose "GPU OCR backend"))
    (optional "Dragonfly" (purpose "Cross-locale L2 cache"))
    (build "Idris2" (purpose "ABI formal proofs"))))
