# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
Data analysis functions for extracted PDF content.

This module provides statistical analysis, word frequency counting,
and other analytical tools for processed documents.
"""

using Statistics
using DataFrames

"""
    analyze_content(doc::PDFDocument)

Perform comprehensive analysis on an extracted document.

# Arguments
- `doc::PDFDocument`: The extracted document to analyze

# Returns
- `AnalysisResult`: Statistical analysis of the document

# Example
```julia
result = extract_text("document.pdf")
if result.success
    stats = analyze_content(result.document)
    println("Words: $(stats.total_words)")
    println("Unique: $(stats.unique_words)")
end
```
"""
function analyze_content(doc::PDFDocument)
    all_text = text_content(doc)
    words = extract_words(all_text)

    total_words = length(words)
    total_chars = length(all_text)
    unique_words = length(unique(lowercase.(words)))

    avg_per_page = if !isempty(doc.pages)
        total_words / length(doc.pages)
    else
        0.0
    end

    frequencies = word_frequency(words)
    redacted_estimate = estimate_redacted_area(doc)

    return AnalysisResult(
        length(doc.pages),
        total_words,
        total_chars,
        unique_words,
        avg_per_page,
        frequencies,
        redacted_estimate
    )
end

"""
    extract_words(text::String)

Extract words from text, filtering out punctuation.
"""
function extract_words(text::String)
    # Split on whitespace and punctuation
    tokens = split(text, r"[\s\p{P}]+")
    # Filter empty strings and numbers-only
    return filter(t -> !isempty(t) && !occursin(r"^\d+$", t), tokens)
end

"""
    word_frequency(words::Vector{SubString{String}})
    word_frequency(doc::PDFDocument)

Calculate word frequency distribution.

# Returns
- `Dict{String,Int}`: Map of lowercase words to their counts
"""
function word_frequency(words::Vector)
    freq = Dict{String,Int}()
    for word in words
        key = lowercase(String(word))
        freq[key] = get(freq, key, 0) + 1
    end
    return freq
end

function word_frequency(doc::PDFDocument)
    all_text = text_content(doc)
    words = extract_words(all_text)
    return word_frequency(words)
end

"""
    top_words(doc::PDFDocument; n::Int=20, exclude_common::Bool=true)

Get the most frequent words in a document.

# Arguments
- `doc::PDFDocument`: Document to analyze
- `n::Int`: Number of top words to return
- `exclude_common::Bool`: Whether to exclude common stop words

# Returns
- `Vector{Tuple{String,Int}}`: Word-count pairs sorted by frequency
"""
function top_words(doc::PDFDocument; n::Int=20, exclude_common::Bool=true)
    freq = word_frequency(doc)

    if exclude_common
        # Common English stop words
        stop_words = Set([
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to",
            "for", "of", "with", "by", "from", "as", "is", "was", "are",
            "were", "been", "be", "have", "has", "had", "do", "does", "did",
            "will", "would", "could", "should", "may", "might", "must",
            "that", "which", "who", "whom", "this", "these", "those",
            "it", "its", "i", "you", "he", "she", "we", "they", "them"
        ])
        filter!(p -> !(p.first in stop_words), freq)
    end

    sorted = sort(collect(freq), by=x -> -x.second)
    return [(p.first, p.second) for p in sorted[1:min(n, length(sorted))]]
end

"""
    estimate_redacted_area(doc::PDFDocument)

Estimate the percentage of page area that may be redacted.

This is a heuristic based on the ratio of extracted text area to total page area.
Lower ratios may indicate more redacted content.
"""
function estimate_redacted_area(doc::PDFDocument)
    if isempty(doc.pages)
        return 0.0
    end

    total_page_area = sum(page_area(p) for p in doc.pages)
    total_text_area = 0.0

    for page in doc.pages
        for block in page.blocks
            total_text_area += block_area(block)
        end
    end

    if total_page_area == 0
        return 0.0
    end

    # Expected text coverage is roughly 30-50% for typical documents
    expected_coverage = 0.4
    actual_coverage = total_text_area / total_page_area

    # If actual coverage is significantly lower, estimate redaction
    if actual_coverage < expected_coverage
        return (expected_coverage - actual_coverage) / expected_coverage * 100
    else
        return 0.0
    end
end

"""
    redaction_coverage(doc::PDFDocument)

Detailed analysis of potential redaction coverage per page.

# Returns
- `DataFrame`: Per-page analysis with columns for page, text area, and coverage
"""
function redaction_coverage(doc::PDFDocument)
    rows = []

    for page in doc.pages
        total_area = page_area(page)
        text_area = sum(block_area(b) for b in page.blocks; init=0.0)
        coverage = text_area / total_area * 100

        push!(rows, (
            page = page.page_number,
            page_area = total_area,
            text_area = text_area,
            coverage_pct = coverage,
            word_count = length(page.blocks)
        ))
    end

    return DataFrame(rows)
end

"""
    document_summary(doc::PDFDocument)

Generate a summary DataFrame for a document.
"""
function document_summary(doc::PDFDocument)
    analysis = analyze_content(doc)

    return DataFrame(
        metric = [
            "File",
            "SHA-256",
            "Pages",
            "Total Words",
            "Unique Words",
            "Total Characters",
            "Avg Words/Page",
            "Estimated Redacted %"
        ],
        value = [
            doc.filepath,
            doc.sha256[1:16] * "...",
            analysis.total_pages,
            analysis.total_words,
            analysis.unique_words,
            analysis.total_characters,
            round(analysis.avg_words_per_page, digits=1),
            round(analysis.estimated_redacted_area, digits=1)
        ]
    )
end

"""
    compare_documents(docs::Vector{PDFDocument})

Compare multiple documents and generate comparative statistics.

# Returns
- `DataFrame`: Comparison table with metrics for each document
"""
function compare_documents(docs::Vector{PDFDocument})
    if isempty(docs)
        return DataFrame()
    end

    rows = []
    for doc in docs
        analysis = analyze_content(doc)
        push!(rows, (
            file = basename(doc.filepath),
            pages = analysis.total_pages,
            words = analysis.total_words,
            unique = analysis.unique_words,
            chars = analysis.total_characters,
            avg_words = round(analysis.avg_words_per_page, digits=1),
            redacted_pct = round(analysis.estimated_redacted_area, digits=1)
        ))
    end

    return DataFrame(rows)
end

"""
    search_content(doc::PDFDocument, pattern::Regex)

Search for a pattern in document content.

# Returns
- `Vector{NamedTuple}`: Matches with page number and context
"""
function search_content(doc::PDFDocument, pattern::Regex)
    matches = []

    for page in doc.pages
        content = text_content(page)
        for m in eachmatch(pattern, content)
            # Get context (30 chars before and after)
            start_ctx = max(1, m.offset - 30)
            end_ctx = min(length(content), m.offset + length(m.match) + 30)
            context = content[start_ctx:end_ctx]

            push!(matches, (
                page = page.page_number,
                match = m.match,
                context = context
            ))
        end
    end

    return matches
end
