# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
    Docudactyl

A Julia-based PDF text extraction and analysis tool with parallel processing support.
Designed to recover text from poorly redacted documents where underlying text data
remains accessible in the PDF stream.

## Features
- Parallel processing for batch document analysis
- Text extraction with positional data preservation
- Data analysis and statistics on extracted content
- Export to multiple formats (CSV, JSON, Scheme)

## Usage
    using Docudactyl

    # Single file extraction
    result = extract_text("document.pdf")

    # Parallel batch processing
    results = parallel_extract(["doc1.pdf", "doc2.pdf", "doc3.pdf"])

    # Analysis
    stats = analyze_content(result)
"""
module Docudactyl

using Distributed
using DataFrames
using CSV
using JSON3
using SHA
using Dates
using Statistics
using Printf

# Include submodules
include("types.jl")
include("extract.jl")
include("parallel.jl")
include("analysis.jl")
include("export.jl")
include("cli.jl")

# Export public API
export PDFDocument, TextBlock, PageContent, ExtractionResult
export extract_text, extract_page, extract_all_pages
export parallel_extract, parallel_analyze
export analyze_content, word_frequency, redaction_coverage
export export_csv, export_json, export_scheme
export run_cli

# Version info
const VERSION = v"0.4.0"
const PROGRAM_NAME = "Docudactyl"

"""
    version()

Return the current version of Docudactyl.
"""
version() = VERSION

"""
    info()

Print information about the Docudactyl module.
"""
function info()
    println("$PROGRAM_NAME v$VERSION")
    println("Julia-based PDF text extraction with parallel processing")
    println("Workers available: $(nworkers())")
end

end # module
