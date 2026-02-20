# SPDX-FileCopyrightText: 2025 Hyperpolymath
# SPDX-License-Identifier: PMPL-1.0-or-later

"""
Parallel processing utilities for batch PDF extraction.

This module provides functions for processing multiple PDF files
concurrently using Julia's Distributed computing capabilities.
"""

using Distributed

"""
    parallel_extract(filepaths::Vector{String};
                     workers::Int=nworkers(),
                     progress::Bool=true)

Extract text from multiple PDF files in parallel.

# Arguments
- `filepaths::Vector{String}`: Vector of PDF file paths
- `workers::Int`: Number of workers to use (default: all available)
- `progress::Bool`: Whether to show progress updates

# Returns
- `Vector{ExtractionResult}`: Results for each file

# Example
```julia
# Add workers if needed
using Distributed
addprocs(4)
@everywhere using Docudactyl

files = readdir("pdfs/", join=true)
results = parallel_extract(files)
```
"""
function parallel_extract(filepaths::Vector{String};
                          workers::Int=nworkers(),
                          progress::Bool=true)
    n_files = length(filepaths)

    if n_files == 0
        return ExtractionResult[]
    end

    if progress
        println("Processing $n_files files with $workers workers...")
    end

    # Use pmap for parallel processing
    results = pmap(filepaths; batch_size=max(1, n_files ÷ workers)) do filepath
        extract_text(filepath)
    end

    if progress
        successes = count(r -> r.success, results)
        println("Completed: $successes/$n_files successful")
    end

    return results
end

"""
    parallel_extract_dir(directory::String;
                         pattern::String="*.pdf",
                         recursive::Bool=false,
                         workers::Int=nworkers())

Extract text from all PDFs in a directory.

# Arguments
- `directory::String`: Path to directory containing PDFs
- `pattern::String`: Glob pattern for matching files
- `recursive::Bool`: Whether to search subdirectories
- `workers::Int`: Number of workers to use

# Returns
- `Vector{ExtractionResult}`: Results for each file found
"""
function parallel_extract_dir(directory::String;
                              pattern::String="*.pdf",
                              recursive::Bool=false,
                              workers::Int=nworkers())
    # Collect matching files
    filepaths = String[]

    if recursive
        for (root, dirs, files) in walkdir(directory)
            for file in files
                if occursin(r"\.pdf$"i, file)
                    push!(filepaths, joinpath(root, file))
                end
            end
        end
    else
        for file in readdir(directory)
            if occursin(r"\.pdf$"i, file)
                push!(filepaths, joinpath(directory, file))
            end
        end
    end

    if isempty(filepaths)
        @warn "No PDF files found in $directory"
        return ExtractionResult[]
    end

    return parallel_extract(filepaths; workers=workers)
end

"""
    parallel_analyze(results::Vector{ExtractionResult};
                     workers::Int=nworkers())

Analyze multiple extraction results in parallel.

# Arguments
- `results::Vector{ExtractionResult}`: Results from parallel_extract
- `workers::Int`: Number of workers to use

# Returns
- `Vector{Union{AnalysisResult,Nothing}}`: Analysis for each successful extraction
"""
function parallel_analyze(results::Vector{ExtractionResult};
                          workers::Int=nworkers())
    return pmap(results) do result
        if result.success && result.document !== nothing
            analyze_content(result.document)
        else
            nothing
        end
    end
end

"""
    batch_process(filepaths::Vector{String};
                  output_dir::String="output",
                  format::Symbol=:json,
                  workers::Int=nworkers())

Process multiple PDFs and export results.

# Arguments
- `filepaths::Vector{String}`: PDF files to process
- `output_dir::String`: Directory for output files
- `format::Symbol`: Export format (:csv, :json, or :scheme)
- `workers::Int`: Number of workers to use

# Returns
- `NamedTuple`: Summary statistics
"""
function batch_process(filepaths::Vector{String};
                       output_dir::String="output",
                       format::Symbol=:json,
                       workers::Int=nworkers())
    # Create output directory
    mkpath(output_dir)

    # Extract in parallel
    start_time = time()
    results = parallel_extract(filepaths; workers=workers)
    extraction_time = time() - start_time

    # Export results
    exported = 0
    for (i, result) in enumerate(results)
        if result.success && result.document !== nothing
            basename_pdf = basename(filepaths[i])
            name_only = replace(basename_pdf, r"\.pdf$"i => "")

            output_path = if format == :csv
                joinpath(output_dir, "$name_only.csv")
            elseif format == :json
                joinpath(output_dir, "$name_only.json")
            elseif format == :scheme
                joinpath(output_dir, "$name_only.scm")
            else
                joinpath(output_dir, "$name_only.txt")
            end

            try
                if format == :csv
                    export_csv(result.document, output_path)
                elseif format == :json
                    export_json(result.document, output_path)
                elseif format == :scheme
                    export_scheme(result.document, output_path)
                end
                exported += 1
            catch e
                @warn "Failed to export $(filepaths[i]): $e"
            end
        end
    end

    successes = count(r -> r.success, results)
    failures = length(results) - successes

    return (
        total = length(filepaths),
        successful = successes,
        failed = failures,
        exported = exported,
        extraction_time_s = extraction_time,
        output_dir = output_dir
    )
end

"""
    setup_workers(n::Int=0)

Set up worker processes for parallel processing.

# Arguments
- `n::Int`: Number of workers to add (0 = auto-detect based on CPU cores)
"""
function setup_workers(n::Int=0)
    current_workers = nworkers()

    if n == 0
        n = Sys.CPU_THREADS - 1  # Leave one core for main process
    end

    if current_workers < n
        to_add = n - current_workers
        addprocs(to_add)
        println("Added $to_add workers (total: $(nworkers()))")

        # Load Docudactyl on all workers
        @everywhere using Docudactyl
    else
        println("Already have $current_workers workers")
    end

    return nworkers()
end

"""
    worker_status()

Print status of distributed workers.
"""
function worker_status()
    n = nworkers()
    println("Workers: $n")
    for w in workers()
        println("  Worker $w: ready")
    end
end
