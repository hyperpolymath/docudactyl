# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
Export functions for extracted PDF content.

Supports multiple output formats:
- CSV: Tabular data for spreadsheet analysis
- JSON: Structured data for APIs and web applications
- Scheme (S-expressions): Machine-readable format for Lisp processing
"""

using JSON3
using CSV
using DataFrames
using Printf

"""
    export_csv(doc::PDFDocument, filepath::String)

Export document content to CSV format.

Creates a CSV with columns: page, line_number, text, x0, y0, word_count

# Arguments
- `doc::PDFDocument`: Document to export
- `filepath::String`: Output file path
"""
function export_csv(doc::PDFDocument, filepath::String)
    rows = []

    for page in doc.pages
        for (line_num, line) in enumerate(page.lines)
            push!(rows, (
                page = page.page_number,
                line_number = line_num,
                text = line,
                word_count = length(split(line))
            ))
        end

        # Also include individual blocks if lines are empty
        if isempty(page.lines)
            for (i, block) in enumerate(page.blocks)
                push!(rows, (
                    page = page.page_number,
                    line_number = i,
                    text = block.text,
                    word_count = 1
                ))
            end
        end
    end

    df = DataFrame(rows)
    CSV.write(filepath, df)

    return filepath
end

"""
    export_json(doc::PDFDocument, filepath::String; pretty::Bool=true)

Export document content to JSON format.

# Arguments
- `doc::PDFDocument`: Document to export
- `filepath::String`: Output file path
- `pretty::Bool`: Whether to format with indentation
"""
function export_json(doc::PDFDocument, filepath::String; pretty::Bool=true)
    # Build JSON structure
    data = Dict(
        "metadata" => Dict(
            "filepath" => doc.filepath,
            "sha256" => doc.sha256,
            "extracted_at" => string(doc.extracted_at),
            "pdf_metadata" => doc.metadata
        ),
        "pages" => [
            Dict(
                "page_number" => page.page_number,
                "width" => page.width,
                "height" => page.height,
                "lines" => page.lines,
                "blocks" => [
                    Dict(
                        "text" => block.text,
                        "x0" => block.x0,
                        "y0" => block.y0,
                        "x1" => block.x1,
                        "y1" => block.y1,
                        "font_size" => block.font_size
                    )
                    for block in page.blocks
                ]
            )
            for page in doc.pages
        ]
    )

    open(filepath, "w") do io
        if pretty
            JSON3.pretty(io, data)
        else
            JSON3.write(io, data)
        end
    end

    return filepath
end

"""
    export_scheme(doc::PDFDocument, filepath::String)

Export document content to Scheme (S-expression) format.

This creates a machine-readable Lisp data structure that can be
processed by Guile, Racket, or other Scheme implementations.

# Arguments
- `doc::PDFDocument`: Document to export
- `filepath::String`: Output file path
"""
function export_scheme(doc::PDFDocument, filepath::String)
    open(filepath, "w") do io
        println(io, ";; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>")
        println(io, ";; SPDX-License-Identifier: PMPL-1.0-or-later")
        println(io, ";;")
        println(io, ";; Docudactyl PDF extraction - Scheme export")
        println(io, ";; Generated: $(Dates.now())")
        println(io)
        println(io, "(define docudactyl-document")
        println(io, "  `((metadata")
        println(io, "     (filepath . \"$(escape_string(doc.filepath))\")")
        println(io, "     (sha256 . \"$(doc.sha256)\")")
        println(io, "     (extracted-at . \"$(doc.extracted_at)\")")
        println(io, "     (pdf-metadata")

        for (key, value) in doc.metadata
            println(io, "       ($(lowercase(key)) . \"$(escape_string(string(value)))\")")
        end

        println(io, "       ))")

        println(io, "    (pages")

        for page in doc.pages
            println(io, "      ((page-number . $(page.page_number))")
            println(io, "       (dimensions (width . $(page.width)) (height . $(page.height)))")
            println(io, "       (content")

            for line in page.lines
                println(io, "         \"$(escape_string(line))\"")
            end

            println(io, "         )")

            println(io, "       (blocks")
            for block in page.blocks
                println(io, "         ((text . \"$(escape_string(block.text))\")")
                println(io, "          (bounds (x0 . $(block.x0)) (y0 . $(block.y0))")
                println(io, "                  (x1 . $(block.x1)) (y1 . $(block.y1)))")
                println(io, "          (font-size . $(block.font_size)))")
            end
            println(io, "         ))")
        end

        println(io, "      )))")
    end

    return filepath
end

"""
    escape_string(s::String)

Escape special characters for Scheme string literals.
"""
function escape_string(s::String)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

"""
    export_text(doc::PDFDocument, filepath::String)

Export document as plain text.
"""
function export_text(doc::PDFDocument, filepath::String)
    open(filepath, "w") do io
        for (i, page) in enumerate(doc.pages)
            if i > 1
                println(io, "\n--- Page $(page.page_number) ---\n")
            end
            println(io, text_content(page))
        end
    end

    return filepath
end

"""
    export_dataframe(doc::PDFDocument)

Convert document to a DataFrame for in-memory analysis.
"""
function export_dataframe(doc::PDFDocument)
    rows = []

    for page in doc.pages
        for block in page.blocks
            push!(rows, (
                page = page.page_number,
                text = block.text,
                x0 = block.x0,
                y0 = block.y0,
                x1 = block.x1,
                y1 = block.y1,
                font_size = block.font_size,
                width = block.x1 - block.x0,
                height = block.y1 - block.y0
            ))
        end
    end

    return DataFrame(rows)
end

"""
    export_summary(results::Vector{ExtractionResult}, filepath::String)

Export a summary of batch processing results.
"""
function export_summary(results::Vector{ExtractionResult}, filepath::String)
    rows = []

    for result in results
        if result.success && result.document !== nothing
            doc = result.document
            analysis = analyze_content(doc)

            push!(rows, (
                filepath = doc.filepath,
                sha256 = doc.sha256[1:16],
                success = true,
                pages = analysis.total_pages,
                words = analysis.total_words,
                unique_words = analysis.unique_words,
                duration_ms = result.duration_ms,
                error = ""
            ))
        else
            push!(rows, (
                filepath = "",
                sha256 = "",
                success = false,
                pages = 0,
                words = 0,
                unique_words = 0,
                duration_ms = result.duration_ms,
                error = something(result.error, "Unknown error")
            ))
        end
    end

    df = DataFrame(rows)
    CSV.write(filepath, df)

    return filepath
end
