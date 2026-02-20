# SPDX-FileCopyrightText: 2025 Hyperpolymath
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
PDF text extraction functions.

This module handles the core extraction of text from PDF files,
including text that may be visually obscured by redaction rectangles
but remains in the PDF stream.
"""

using PDFIO
using SHA

# Constants for text reconstruction
const DEFAULT_LINE_TOLERANCE = 2.0  # Points tolerance for line grouping
const DEFAULT_SPACE_WIDTH = 4.0     # Minimum gap to insert space
const MIN_FONT_SIZE = 4.0           # Minimum recognizable font size

"""
    compute_file_hash(filepath::String)

Compute SHA-256 hash of a file for integrity verification.
"""
function compute_file_hash(filepath::String)
    open(filepath, "r") do io
        return bytes2hex(sha256(io))
    end
end

"""
    extract_text(filepath::String; line_tolerance=DEFAULT_LINE_TOLERANCE)

Extract all text from a PDF file, returning an ExtractionResult.

# Arguments
- `filepath::String`: Path to the PDF file
- `line_tolerance::Float64`: Vertical tolerance for grouping words into lines

# Returns
- `ExtractionResult`: Contains the extracted document or error information

# Example
```julia
result = extract_text("document.pdf")
if result.success
    println(text_content(result.document))
end
```
"""
function extract_text(filepath::String; line_tolerance::Float64=DEFAULT_LINE_TOLERANCE)
    start_time = time_ns()

    try
        # Verify file exists
        if !isfile(filepath)
            return ExtractionResult(
                false, nothing,
                "File not found: $filepath",
                (time_ns() - start_time) / 1e6
            )
        end

        # Compute hash for integrity
        file_hash = compute_file_hash(filepath)

        # Open PDF
        doc = pdDocOpen(filepath)

        try
            # Extract metadata
            metadata = extract_metadata(doc)

            # Extract pages
            pages = PageContent[]
            num_pages = pdDocGetPageCount(doc)

            for page_num in 1:num_pages
                page_content = extract_page(doc, page_num, line_tolerance)
                push!(pages, page_content)
            end

            # Create document
            pdf_doc = PDFDocument(
                filepath,
                file_hash,
                pages,
                metadata,
                Dates.now()
            )

            return ExtractionResult(
                true, pdf_doc, nothing,
                (time_ns() - start_time) / 1e6
            )
        finally
            pdDocClose(doc)
        end

    catch e
        return ExtractionResult(
            false, nothing,
            "Extraction error: $(sprint(showerror, e))",
            (time_ns() - start_time) / 1e6
        )
    end
end

"""
    extract_metadata(doc)

Extract metadata from a PDF document.
"""
function extract_metadata(doc)
    metadata = Dict{String,Any}()

    try
        info = pdDocGetInfo(doc)
        if info !== nothing
            # Standard PDF metadata fields
            for field in [:Title, :Author, :Subject, :Keywords, :Creator, :Producer]
                if haskey(info, field)
                    metadata[string(field)] = info[field]
                end
            end
        end
    catch
        # Metadata extraction failed, return empty dict
    end

    return metadata
end

"""
    extract_page(doc, page_num::Int, line_tolerance::Float64)

Extract content from a single PDF page.
"""
function extract_page(doc, page_num::Int, line_tolerance::Float64)
    page = pdDocGetPage(doc, page_num)

    # Get page dimensions
    media_box = pdPageGetMediaBox(page)
    width = media_box[3] - media_box[1]
    height = media_box[4] - media_box[2]

    # Extract text content
    blocks = extract_text_blocks(page, page_num)

    # Group into lines
    lines = group_into_lines(blocks, line_tolerance)

    return PageContent(page_num, width, height, blocks, lines)
end

"""
    extract_text_blocks(page, page_num::Int)

Extract individual text blocks from a page with their positions.
"""
function extract_text_blocks(page, page_num::Int)
    blocks = TextBlock[]

    try
        # Extract text using PDFIO
        text_content = pdPageExtractText(page)

        if text_content !== nothing && !isempty(strip(text_content))
            # Parse the extracted text
            # Note: PDFIO provides basic extraction; for detailed positioning,
            # we'd need to parse the content stream directly
            words = split(text_content)

            # Estimate positions (simplified - real implementation would
            # parse content stream for exact coordinates)
            x_pos = 72.0  # Standard margin
            y_pos = 72.0

            for (i, word) in enumerate(words)
                if !isempty(word)
                    estimated_width = length(word) * 6.0  # Approximate char width

                    block = TextBlock(
                        String(word),
                        x_pos,
                        y_pos,
                        x_pos + estimated_width,
                        y_pos + 12.0,
                        12.0,
                        page_num
                    )
                    push!(blocks, block)

                    x_pos += estimated_width + 6.0
                    if x_pos > 540.0  # Page width - margin
                        x_pos = 72.0
                        y_pos += 14.0
                    end
                end
            end
        end
    catch e
        @warn "Error extracting text from page $page_num: $e"
    end

    return blocks
end

"""
    group_into_lines(blocks::Vector{TextBlock}, tolerance::Float64)

Group text blocks into lines based on vertical position.
"""
function group_into_lines(blocks::Vector{TextBlock}, tolerance::Float64)
    if isempty(blocks)
        return String[]
    end

    # Sort blocks by vertical position, then horizontal
    sorted_blocks = sort(blocks, by=b -> (b.y0, b.x0))

    lines = String[]
    current_line_blocks = TextBlock[]
    current_y = sorted_blocks[1].y0

    for block in sorted_blocks
        if abs(block.y0 - current_y) <= tolerance
            # Same line
            push!(current_line_blocks, block)
        else
            # New line - flush current
            if !isempty(current_line_blocks)
                line_text = build_line_text(current_line_blocks)
                push!(lines, line_text)
            end
            current_line_blocks = [block]
            current_y = block.y0
        end
    end

    # Flush final line
    if !isempty(current_line_blocks)
        line_text = build_line_text(current_line_blocks)
        push!(lines, line_text)
    end

    return lines
end

"""
    build_line_text(blocks::Vector{TextBlock})

Reconstruct a line of text from blocks, adding appropriate spacing.
"""
function build_line_text(blocks::Vector{TextBlock})
    if isempty(blocks)
        return ""
    end

    # Sort by x position
    sorted = sort(blocks, by=b -> b.x0)

    parts = String[]
    prev_end = 0.0

    for (i, block) in enumerate(sorted)
        if i > 1
            gap = block.x0 - prev_end
            if gap > DEFAULT_SPACE_WIDTH
                # Calculate number of spaces based on gap size
                num_spaces = max(1, round(Int, gap / DEFAULT_SPACE_WIDTH))
                push!(parts, " "^num_spaces)
            end
        end
        push!(parts, block.text)
        prev_end = block.x1
    end

    return join(parts)
end

"""
    extract_all_pages(filepath::String)

Extract text from all pages, returning a vector of strings (one per page).
"""
function extract_all_pages(filepath::String)
    result = extract_text(filepath)
    if result.success
        return [text_content(page) for page in result.document.pages]
    else
        error(result.error)
    end
end
