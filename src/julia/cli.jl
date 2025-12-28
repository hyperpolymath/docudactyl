# SPDX-FileCopyrightText: 2025 Hyperpolymath
# SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-Palimpsest-0.5

"""
Command-line interface for Docudactyl.
"""

using ArgParse

"""
    parse_commandline()

Parse command-line arguments.
"""
function parse_commandline()
    s = ArgParseSettings(
        prog = "docudactyl",
        description = "PDF text extraction with parallel processing",
        version = string(VERSION),
        add_version = true
    )

    @add_arg_table! s begin
        "input"
            help = "Input PDF file or directory"
            required = true

        "--output", "-o"
            help = "Output file or directory"
            default = ""

        "--format", "-f"
            help = "Output format: text, csv, json, scheme"
            default = "text"

        "--recursive", "-r"
            help = "Recursively process directories"
            action = :store_true

        "--workers", "-w"
            help = "Number of parallel workers (0 = auto)"
            arg_type = Int
            default = 0

        "--analyze", "-a"
            help = "Perform content analysis"
            action = :store_true

        "--quiet", "-q"
            help = "Suppress progress output"
            action = :store_true

        "--line-tolerance"
            help = "Vertical tolerance for line grouping (points)"
            arg_type = Float64
            default = 2.0
    end

    return parse_args(s)
end

"""
    run_cli()

Main CLI entry point.
"""
function run_cli()
    args = parse_commandline()

    input_path = args["input"]
    output_path = args["output"]
    format = Symbol(lowercase(args["format"]))
    recursive = args["recursive"]
    workers = args["workers"]
    analyze = args["analyze"]
    quiet = args["quiet"]

    # Set up workers if needed
    if workers > 0 || (workers == 0 && isdir(input_path))
        setup_workers(workers)
    end

    # Process input
    if isdir(input_path)
        process_directory(input_path, output_path, format, recursive, !quiet, analyze)
    elseif isfile(input_path)
        process_single_file(input_path, output_path, format, !quiet, analyze)
    else
        println(stderr, "Error: Input path not found: $input_path")
        exit(1)
    end
end

"""
    process_single_file(input::String, output::String, format::Symbol,
                        verbose::Bool, analyze::Bool)

Process a single PDF file.
"""
function process_single_file(input::String, output::String, format::Symbol,
                             verbose::Bool, analyze::Bool)
    if verbose
        println("Processing: $input")
    end

    result = extract_text(input)

    if !result.success
        println(stderr, "Error: $(result.error)")
        exit(1)
    end

    doc = result.document

    # Determine output path
    if isempty(output)
        ext = format == :text ? "txt" : string(format)
        output = replace(input, r"\.pdf$"i => ".$ext")
    end

    # Export
    if format == :text
        export_text(doc, output)
    elseif format == :csv
        export_csv(doc, output)
    elseif format == :json
        export_json(doc, output)
    elseif format == :scheme
        export_scheme(doc, output)
    else
        println(stderr, "Unknown format: $format")
        exit(1)
    end

    if verbose
        println("Output: $output")
        println("Duration: $(round(result.duration_ms, digits=1)) ms")
    end

    # Analyze if requested
    if analyze
        stats = analyze_content(doc)
        println("\nAnalysis:")
        println("  Pages: $(stats.total_pages)")
        println("  Words: $(stats.total_words)")
        println("  Unique words: $(stats.unique_words)")
        println("  Avg words/page: $(round(stats.avg_words_per_page, digits=1))")
        println("  Est. redacted: $(round(stats.estimated_redacted_area, digits=1))%")

        println("\nTop 10 words:")
        for (word, count) in top_words(doc; n=10)
            println("  $word: $count")
        end
    end
end

"""
    process_directory(input::String, output::String, format::Symbol,
                      recursive::Bool, verbose::Bool, analyze::Bool)

Process all PDFs in a directory.
"""
function process_directory(input::String, output::String, format::Symbol,
                           recursive::Bool, verbose::Bool, analyze::Bool)
    # Collect files
    filepaths = String[]

    if recursive
        for (root, dirs, files) in walkdir(input)
            for file in files
                if occursin(r"\.pdf$"i, file)
                    push!(filepaths, joinpath(root, file))
                end
            end
        end
    else
        for file in readdir(input)
            if occursin(r"\.pdf$"i, file)
                push!(filepaths, joinpath(input, file))
            end
        end
    end

    if isempty(filepaths)
        println(stderr, "No PDF files found in: $input")
        exit(1)
    end

    if verbose
        println("Found $(length(filepaths)) PDF files")
    end

    # Determine output directory
    output_dir = isempty(output) ? joinpath(input, "extracted") : output

    # Batch process
    summary = batch_process(filepaths;
                            output_dir=output_dir,
                            format=format,
                            workers=nworkers())

    if verbose
        println("\nBatch processing complete:")
        println("  Total: $(summary.total)")
        println("  Successful: $(summary.successful)")
        println("  Failed: $(summary.failed)")
        println("  Exported: $(summary.exported)")
        println("  Time: $(round(summary.extraction_time_s, digits=2)) s")
        println("  Output: $(summary.output_dir)")
    end
end

# Entry point when run as script
if abspath(PROGRAM_FILE) == @__FILE__
    run_cli()
end
