# SPDX-FileCopyrightText: 2025 Hyperpolymath
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
Type definitions for Docudactyl PDF extraction.
"""

"""
    TextBlock

Represents a single text element extracted from a PDF with its positioning.

# Fields
- `text::String`: The extracted text content
- `x0::Float64`: Left x-coordinate (points from left)
- `y0::Float64`: Top y-coordinate (points from top)
- `x1::Float64`: Right x-coordinate
- `y1::Float64`: Bottom y-coordinate
- `font_size::Float64`: Estimated font size in points
- `page::Int`: Page number (1-indexed)
"""
struct TextBlock
    text::String
    x0::Float64
    y0::Float64
    x1::Float64
    y1::Float64
    font_size::Float64
    page::Int
end

"""
    PageContent

Container for all text blocks on a single page.

# Fields
- `page_number::Int`: The page number (1-indexed)
- `width::Float64`: Page width in points
- `height::Float64`: Page height in points
- `blocks::Vector{TextBlock}`: All text blocks on this page
- `lines::Vector{String}`: Reconstructed lines of text
"""
struct PageContent
    page_number::Int
    width::Float64
    height::Float64
    blocks::Vector{TextBlock}
    lines::Vector{String}
end

"""
    PDFDocument

Represents a complete PDF document with all extracted content.

# Fields
- `filepath::String`: Original file path
- `sha256::String`: SHA-256 hash of the file
- `pages::Vector{PageContent}`: Content from all pages
- `metadata::Dict{String,Any}`: PDF metadata (title, author, etc.)
- `extracted_at::DateTime`: Timestamp of extraction
"""
struct PDFDocument
    filepath::String
    sha256::String
    pages::Vector{PageContent}
    metadata::Dict{String,Any}
    extracted_at::DateTime
end

"""
    ExtractionResult

Result container for extraction operations, including success/failure status.

# Fields
- `success::Bool`: Whether extraction succeeded
- `document::Union{PDFDocument,Nothing}`: The extracted document (if successful)
- `error::Union{String,Nothing}`: Error message (if failed)
- `duration_ms::Float64`: Time taken for extraction in milliseconds
"""
struct ExtractionResult
    success::Bool
    document::Union{PDFDocument,Nothing}
    error::Union{String,Nothing}
    duration_ms::Float64
end

"""
    AnalysisResult

Statistical analysis results for extracted content.

# Fields
- `total_pages::Int`: Number of pages analyzed
- `total_words::Int`: Total word count
- `total_characters::Int`: Total character count
- `unique_words::Int`: Count of unique words
- `avg_words_per_page::Float64`: Average words per page
- `word_frequencies::Dict{String,Int}`: Word frequency map
- `estimated_redacted_area::Float64`: Percentage of page area potentially redacted
"""
struct AnalysisResult
    total_pages::Int
    total_words::Int
    total_characters::Int
    unique_words::Int
    avg_words_per_page::Float64
    word_frequencies::Dict{String,Int}
    estimated_redacted_area::Float64
end

# Convenience constructors

"""
    TextBlock(text, x0, y0, page)

Create a TextBlock with minimal positioning info.
"""
TextBlock(text::String, x0::Float64, y0::Float64, page::Int) =
    TextBlock(text, x0, y0, x0 + length(text) * 6.0, y0 + 12.0, 12.0, page)

"""
    PageContent(page_number, blocks)

Create PageContent with default page dimensions (letter size).
"""
PageContent(page_number::Int, blocks::Vector{TextBlock}) =
    PageContent(page_number, 612.0, 792.0, blocks, String[])

# Helper functions for types

"""
    text_content(page::PageContent)

Get all text from a page as a single string.
"""
function text_content(page::PageContent)
    if !isempty(page.lines)
        return join(page.lines, "\n")
    else
        return join([b.text for b in page.blocks], " ")
    end
end

"""
    text_content(doc::PDFDocument)

Get all text from a document as a single string.
"""
function text_content(doc::PDFDocument)
    return join([text_content(p) for p in doc.pages], "\n\n")
end

"""
    block_area(block::TextBlock)

Calculate the bounding box area of a text block.
"""
function block_area(block::TextBlock)
    return abs(block.x1 - block.x0) * abs(block.y1 - block.y0)
end

"""
    page_area(page::PageContent)

Calculate the total area of a page.
"""
function page_area(page::PageContent)
    return page.width * page.height
end
