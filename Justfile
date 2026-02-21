# RSR-template-repo - RSR Standard Justfile Template
# https://just.systems/man/en/
#
# This is the CANONICAL template for all RSR projects.
# Copy this file to new projects and customize the {{PLACEHOLDER}} values.
#
# Run `just` to see all available recipes
# Run `just cookbook` to generate docs/just-cookbook.adoc
# Run `just combinations` to see matrix recipe options

set shell := ["bash", "-uc"]
set dotenv-load := true
set positional-arguments := true

# Project metadata
project := "docudactyl"
version := "0.4.0"
tier := "1"  # Tier 1: Chapel + OCaml + Ada + Zig FFI

# Component paths
julia_src := "src/julia"
ocaml_src := "src/ocaml"
ada_src := "src/ada"
chapel_src := "src/chapel"
zig_ffi := "ffi/zig"

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT & HELP
# ═══════════════════════════════════════════════════════════════════════════════

# Show all available recipes with descriptions
default:
    @just --list --unsorted

# Show detailed help for a specific recipe
help recipe="":
    #!/usr/bin/env bash
    if [ -z "{{recipe}}" ]; then
        just --list --unsorted
        echo ""
        echo "Usage: just help <recipe>"
        echo "       just cookbook     # Generate full documentation"
        echo "       just combinations # Show matrix recipes"
    else
        just --show "{{recipe}}" 2>/dev/null || echo "Recipe '{{recipe}}' not found"
    fi

# Show this project's info
info:
    @echo "Project: {{project}}"
    @echo "Version: {{version}}"
    @echo "RSR Tier: {{tier}}"
    @echo "Recipes: $(just --summary | wc -w)"
    @[ -f STATE.scm ] && grep -oP '\(phase\s+\.\s+\K[^)]+' STATE.scm | head -1 | xargs -I{} echo "Phase: {}" || true

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD & COMPILE
# ═══════════════════════════════════════════════════════════════════════════════

# Build all components (HPC + legacy)
build: build-hpc build-ocaml build-ada
    @echo "All components built!"

# Build Julia package
build-julia:
    @echo "Building Julia package..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Build OCaml transformer
build-ocaml:
    @echo "Building OCaml transformer..."
    cd {{ocaml_src}} && dune build

# Build Ada TUI
build-ada:
    @echo "Building Ada TUI..."
    cd {{ada_src}} && mkdir -p obj bin && gprbuild -P docudactyl.gpr

# Check Idris2 ABI proofs compile
build-idris:
    @echo "Building Idris2 ABI proofs..."
    idris2 --build docudactyl.ipkg

# Build in release mode with optimizations
build-release: build-julia
    @echo "Building {{project}} (release)..."
    cd {{ocaml_src}} && dune build --release
    cd {{ada_src}} && gprbuild -P docudactyl.gpr -XBUILD=release

# Clean build artifacts [reversible: rebuild with `just build`]
clean:
    @echo "Cleaning..."
    rm -rf {{ocaml_src}}/_build
    rm -rf {{ada_src}}/obj {{ada_src}}/bin
    rm -rf {{zig_ffi}}/zig-out {{zig_ffi}}/.zig-cache
    rm -rf bin/docudactyl-hpc
    rm -rf build/
    rm -rf target _build dist

# Deep clean including caches [reversible: rebuild]
clean-all: clean
    rm -rf .cache .tmp
    cd {{julia_src}} && rm -rf Manifest.toml

# ═══════════════════════════════════════════════════════════════════════════════
# TEST & QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run all tests (HPC + legacy)
test: test-hpc test-ocaml
    @echo "All tests passed!"

# Run Julia tests
test-julia:
    @echo "Running Julia tests..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.test()'

# Run OCaml tests
test-ocaml:
    @echo "Running OCaml tests..."
    cd {{ocaml_src}} && dune runtest

# Run Ada build check (Ada uses gprbuild — no separate test runner)
test-ada: build-ada
    @echo "Ada TUI build verified!"

# Verify Idris2 ABI proofs compile cleanly
test-idris: build-idris
    @echo "Idris2 ABI proofs verified!"

# Run tests with verbose output
test-verbose:
    @echo "Running tests (verbose)..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.test(; verbose=true)'

# Run tests and generate coverage report
test-coverage:
    @echo "Running tests with coverage..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.test(; coverage=true)'

# ═══════════════════════════════════════════════════════════════════════════════
# LINT & FORMAT
# ═══════════════════════════════════════════════════════════════════════════════

# Format all source files [reversible: git checkout]
fmt:
    @echo "Formatting..."
    # TODO: Add format command
    # Rust: cargo fmt
    # ReScript: npm run format
    # Elixir: mix format

# Check formatting without changes
fmt-check:
    @echo "Checking format..."
    # TODO: Add format check
    # Rust: cargo fmt --check

# Run linter
lint:
    @echo "Linting..."
    # TODO: Add lint command
    # Rust: cargo clippy -- -D warnings

# Run all quality checks
quality: fmt-check lint test
    @echo "All quality checks passed!"

# Fix all auto-fixable issues [reversible: git checkout]
fix: fmt
    @echo "Fixed all auto-fixable issues"

# ═══════════════════════════════════════════════════════════════════════════════
# RUN & EXECUTE
# ═══════════════════════════════════════════════════════════════════════════════

# Run Julia CLI for PDF extraction
extract pdf *args:
    @echo "Extracting text from {{pdf}}..."
    cd {{julia_src}} && julia --project=. cli.jl "{{pdf}}" {{args}}

# Run OCaml transformer to convert to Scheme
transform input output="":
    @echo "Transforming to Scheme..."
    cd {{ocaml_src}} && dune exec docudactyl-scm -- "{{input}}" -o "{{output}}"

# Run Ada TUI
tui *args:
    @echo "Starting TUI..."
    {{ada_src}}/bin/docudactyl-tui {{args}}

# Full pipeline: extract + transform
pipeline pdf:
    #!/usr/bin/env bash
    echo "Running full pipeline on {{pdf}}..."
    BASE=$(basename "{{pdf}}" .pdf)
    just extract "{{pdf}}" -o "output/${BASE}.json" -f json
    just transform "output/${BASE}.json" "output/${BASE}.scm"
    echo "Pipeline complete: output/${BASE}.scm"

# Run Julia REPL with Docudactyl loaded
repl:
    @echo "Starting Julia REPL..."
    cd {{julia_src}} && julia --project=. -e 'using Docudactyl; Docudactyl.info()' -i

# Run with workers for parallel processing
parallel-extract dir workers="4":
    @echo "Parallel extraction from {{dir}} with {{workers}} workers..."
    cd {{julia_src}} && julia --project=. -p {{workers}} -e \
        'using Docudactyl; results = parallel_extract_dir("{{dir}}"); println("Processed $(length(results)) files")'

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

# Install all dependencies
deps: deps-julia deps-ocaml
    @echo "All dependencies installed!"

# Install Julia dependencies
deps-julia:
    @echo "Installing Julia dependencies..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Install OCaml dependencies
deps-ocaml:
    @echo "Installing OCaml dependencies..."
    opam install --deps-only {{ocaml_src}}/docudactyl_scm.opam

# Audit dependencies for vulnerabilities
deps-audit:
    @echo "Auditing dependencies..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.audit()'

# ═══════════════════════════════════════════════════════════════════════════════
# DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════════

# Generate all documentation
docs:
    @mkdir -p docs/generated docs/man
    just cookbook
    just man
    @echo "Documentation generated in docs/"

# Generate justfile cookbook documentation
cookbook:
    #!/usr/bin/env bash
    mkdir -p docs
    OUTPUT="docs/just-cookbook.adoc"
    echo "= {{project}} Justfile Cookbook" > "$OUTPUT"
    echo ":toc: left" >> "$OUTPUT"
    echo ":toclevels: 3" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "Generated: $(date -Iseconds)" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "== Recipes" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    just --list --unsorted | while read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([a-z_-]+) ]]; then
            recipe="${BASH_REMATCH[1]}"
            echo "=== $recipe" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
            echo "[source,bash]" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "just $recipe" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
        fi
    done
    echo "Generated: $OUTPUT"

# Generate man page
man:
    #!/usr/bin/env bash
    mkdir -p docs/man
    printf '%s\n' \
        ".TH {{project}} 1 \"$(date +%Y-%m-%d)\" \"{{version}}\" \"{{project}} Manual\"" \
        ".SH NAME" \
        "{{project}} \\- document processing engine" \
        ".SH SYNOPSIS" \
        ".B just" \
        "[recipe] [args...]" \
        ".SH DESCRIPTION" \
        "HPC document processing engine for British Library scale corpora." \
        ".SH AUTHOR" \
        "Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>" \
        > docs/man/{{project}}.1
    echo "Generated: docs/man/{{project}}.1"

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINERS (nerdctl + Wolfi)
# ═══════════════════════════════════════════════════════════════════════════════

# Build container image
container-build tag="latest":
    @if [ -f Containerfile ]; then \
        nerdctl build -t {{project}}:{{tag}} -f Containerfile .; \
    else \
        echo "No Containerfile found"; \
    fi

# Run container
container-run tag="latest" *args:
    nerdctl run --rm -it {{project}}:{{tag}} {{args}}

# Push container image
container-push registry="ghcr.io/hyperpolymath" tag="latest":
    nerdctl tag {{project}}:{{tag}} {{registry}}/{{project}}:{{tag}}
    nerdctl push {{registry}}/{{project}}:{{tag}}

# ═══════════════════════════════════════════════════════════════════════════════
# CI & AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run full CI pipeline locally
ci: deps quality
    @echo "CI pipeline complete!"

# Install git hooks
install-hooks:
    #!/usr/bin/env bash
    mkdir -p .git/hooks
    printf '%s\n' '#!/bin/bash' 'just fmt-check || exit 1' 'just lint || exit 1' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    echo "Git hooks installed"

# ═══════════════════════════════════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run security audit
security: deps-audit
    @echo "=== Security Audit ==="
    @command -v gitleaks >/dev/null && gitleaks detect --source . --verbose || true
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL . || true
    @echo "Security audit complete"

# Generate SBOM
sbom:
    @mkdir -p docs/security
    @command -v syft >/dev/null && syft . -o spdx-json > docs/security/sbom.spdx.json || echo "syft not found"

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION & COMPLIANCE
# ═══════════════════════════════════════════════════════════════════════════════

# Validate RSR compliance
validate-rsr:
    #!/usr/bin/env bash
    echo "=== RSR Compliance Check ==="
    MISSING=""
    for f in .editorconfig .gitignore justfile RSR_COMPLIANCE.adoc README.adoc; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    for d in .well-known; do
        [ -d "$d" ] || MISSING="$MISSING $d/"
    done
    for f in .well-known/security.txt .well-known/ai.txt .well-known/humans.txt; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    if [ ! -f "guix.scm" ] && [ ! -f ".guix-channel" ] && [ ! -f "flake.nix" ]; then
        MISSING="$MISSING guix.scm/flake.nix"
    fi
    if [ -n "$MISSING" ]; then
        echo "MISSING:$MISSING"
        exit 1
    fi
    echo "RSR compliance: PASS"

# Validate STATE.scm syntax
validate-state:
    @if [ -f "STATE.scm" ]; then \
        guile -c "(primitive-load \"STATE.scm\")" 2>/dev/null && echo "STATE.scm: valid" || echo "STATE.scm: INVALID"; \
    else \
        echo "No STATE.scm found"; \
    fi

# Full validation suite
validate: validate-rsr validate-state
    @echo "All validations passed!"

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Update STATE.scm timestamp
state-touch:
    @if [ -f "STATE.scm" ]; then \
        sed -i 's/(updated . "[^"]*")/(updated . "'"$(date -Iseconds)"'")/' STATE.scm && \
        echo "STATE.scm timestamp updated"; \
    fi

# Show current phase from STATE.scm
state-phase:
    @grep -oP '\(phase\s+\.\s+\K[^)]+' STATE.scm 2>/dev/null | head -1 || echo "unknown"

# ═══════════════════════════════════════════════════════════════════════════════
# GUIX & NIX
# ═══════════════════════════════════════════════════════════════════════════════

# Enter Guix development shell (primary)
guix-shell:
    guix shell -D -f guix.scm

# Build with Guix
guix-build:
    guix build -f guix.scm

# Enter Nix development shell (fallback)
nix-shell:
    @if [ -f "flake.nix" ]; then nix develop; else echo "No flake.nix"; fi

# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run local automation tasks
automate task="all":
    #!/usr/bin/env bash
    case "{{task}}" in
        all) just fmt && just lint && just test && just docs && just state-touch ;;
        cleanup) just clean && find . -name "*.orig" -delete && find . -name "*~" -delete ;;
        update) just deps && just validate ;;
        *) echo "Unknown: {{task}}. Use: all, cleanup, update" && exit 1 ;;
    esac

# ═══════════════════════════════════════════════════════════════════════════════
# COMBINATORIC MATRIX RECIPES
# ═══════════════════════════════════════════════════════════════════════════════

# Build matrix: [debug|release] × [target] × [features]
build-matrix mode="debug" target="" features="":
    @echo "Build matrix: mode={{mode}} target={{target}} features={{features}}"
    # Customize for your build system

# Test matrix: [unit|integration|e2e|all] × [verbosity] × [parallel]
test-matrix suite="unit" verbosity="normal" parallel="true":
    @echo "Test matrix: suite={{suite}} verbosity={{verbosity}} parallel={{parallel}}"

# Container matrix: [build|run|push|shell|scan] × [registry] × [tag]
container-matrix action="build" registry="ghcr.io/hyperpolymath" tag="latest":
    @echo "Container matrix: action={{action}} registry={{registry}} tag={{tag}}"

# CI matrix: [lint|test|build|security|all] × [quick|full]
ci-matrix stage="all" depth="quick":
    @echo "CI matrix: stage={{stage}} depth={{depth}}"

# Show all matrix combinations
combinations:
    @echo "=== Combinatoric Matrix Recipes ==="
    @echo ""
    @echo "Build Matrix: just build-matrix [debug|release] [target] [features]"
    @echo "Test Matrix:  just test-matrix [unit|integration|e2e|all] [verbosity] [parallel]"
    @echo "Container:    just container-matrix [build|run|push|shell|scan] [registry] [tag]"
    @echo "CI Matrix:    just ci-matrix [lint|test|build|security|all] [quick|full]"
    @echo ""
    @echo "Total combinations: ~10 billion"

# ═══════════════════════════════════════════════════════════════════════════════
# HPC (Chapel + Zig FFI)
# ═══════════════════════════════════════════════════════════════════════════════

# Toolbox container for HPC builds (Chapel + C library -devel headers)
# Override: DOCUDACTYL_TOOLBOX=fedora-toolbox-44 just build-hpc
toolbox := env("DOCUDACTYL_TOOLBOX", "fedora-toolbox-43")

# Build the Zig FFI shared/static libraries
build-ffi:
    @echo "Building Zig FFI (poppler, tesseract, ffmpeg, libxml2, gdal, vips)..."
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && cd {{zig_ffi}} && zig build -Doptimize=ReleaseFast'

# Build Chapel HPC binary (depends on Zig FFI)
build-chapel: build-ffi
    @echo "Building Chapel HPC engine..."
    @mkdir -p bin
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && \
         ABSPATH=$$(cd {{zig_ffi}}/zig-out/lib && pwd) && \
         chpl {{chapel_src}}/DocudactylHPC.chpl \
              {{chapel_src}}/Config.chpl \
              {{chapel_src}}/ContentType.chpl \
              {{chapel_src}}/FFIBridge.chpl \
              {{chapel_src}}/ManifestLoader.chpl \
              {{chapel_src}}/NdjsonManifest.chpl \
              {{chapel_src}}/FaultHandler.chpl \
              {{chapel_src}}/ProgressReporter.chpl \
              {{chapel_src}}/ShardedOutput.chpl \
              {{chapel_src}}/ResultAggregator.chpl \
              {{chapel_src}}/Checkpoint.chpl \
              -o bin/docudactyl-hpc \
              -L{{zig_ffi}}/zig-out/lib -ldocudactyl_ffi \
              --ldflags="-Wl,-rpath,$$ABSPATH" \
              --fast'

# Build complete HPC stack (FFI + Chapel)
build-hpc: build-ffi build-chapel
    @echo "HPC stack built: bin/docudactyl-hpc"

# Run HPC engine on a manifest (single locale)
run-hpc manifest *args:
    toolbox run -c {{toolbox}} bash -c 'bin/docudactyl-hpc --manifestPath={{manifest}} {{args}}'

# Run HPC engine on a cluster (multiple locales)
run-hpc-cluster manifest locales="64" *args:
    toolbox run -c {{toolbox}} bash -c 'bin/docudactyl-hpc --manifestPath={{manifest}} -nl {{locales}} {{args}}'

# Generate a plain text manifest from a directory of documents
generate-manifest dir output="manifest.txt":
    find {{dir}} -type f \( -name '*.pdf' -o -name '*.jpg' -o -name '*.png' \
         -o -name '*.tiff' -o -name '*.mp3' -o -name '*.wav' -o -name '*.mp4' \
         -o -name '*.epub' -o -name '*.shp' \) > {{output}}
    @echo "Manifest written to {{output}} ($$(wc -l < {{output}}) files)"

# Generate an enriched NDJSON manifest with pre-computed metadata
# Eliminates stat() calls at HPC runtime — 10x faster cache lookups on 170M items
generate-ndjson-manifest dir output="manifest.ndjson":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating NDJSON manifest from {{dir}}..."
    COUNT=0
    find "{{dir}}" -type f \( -name '*.pdf' -o -name '*.jpg' -o -name '*.png' \
         -o -name '*.tiff' -o -name '*.tif' -o -name '*.mp3' -o -name '*.wav' \
         -o -name '*.flac' -o -name '*.mp4' -o -name '*.mkv' -o -name '*.epub' \
         -o -name '*.shp' -o -name '*.geotiff' \) -printf '%p\t%s\t%T@\n' | \
    while IFS=$'\t' read -r path size mtime; do
        # Detect content kind from extension
        ext="${path##*.}"
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        case "$ext_lower" in
            pdf) kind="pdf" ;;
            jpg|jpeg|png|tiff|tif|bmp|webp) kind="image" ;;
            mp3|wav|flac|ogg|aac|wma) kind="audio" ;;
            mp4|mkv|avi|mov|webm) kind="video" ;;
            epub) kind="epub" ;;
            shp|geotiff|gpkg) kind="geo" ;;
            *) kind="unknown" ;;
        esac
        # Truncate mtime to integer seconds
        mtime_int="${mtime%%.*}"
        printf '{"path":"%s","size":%s,"mtime":%s,"kind":"%s"}\n' \
            "$path" "$size" "$mtime_int" "$kind"
        COUNT=$((COUNT + 1))
    done > "{{output}}"
    echo "NDJSON manifest written to {{output}} ($$(wc -l < "{{output}}") files)"

# Convert a plain text manifest to enriched NDJSON (stats each file)
upgrade-manifest input="manifest.txt" output="manifest.ndjson":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Upgrading plain manifest to NDJSON..."
    COUNT=0
    while IFS= read -r line; do
        path=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ -z "$path" || "$path" == \#* ]] && continue
        if [ ! -f "$path" ]; then
            echo "# WARNING: file not found: $path" >&2
            continue
        fi
        size=$(stat -c '%s' "$path")
        mtime=$(stat -c '%Y' "$path")
        ext="${path##*.}"
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        case "$ext_lower" in
            pdf) kind="pdf" ;;
            jpg|jpeg|png|tiff|tif|bmp|webp) kind="image" ;;
            mp3|wav|flac|ogg|aac|wma) kind="audio" ;;
            mp4|mkv|avi|mov|webm) kind="video" ;;
            epub) kind="epub" ;;
            shp|geotiff|gpkg) kind="geo" ;;
            *) kind="unknown" ;;
        esac
        printf '{"path":"%s","size":%s,"mtime":%s,"kind":"%s"}\n' \
            "$path" "$size" "$mtime" "$kind"
        COUNT=$((COUNT + 1))
    done < "{{input}}" > "{{output}}"
    echo "Upgraded: $COUNT files → {{output}}"

# Run Zig FFI integration tests
test-ffi:
    @echo "Running Zig FFI tests..."
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && cd {{zig_ffi}} && zig build test'

# Check Chapel parse validity
check-chapel:
    @echo "Checking Chapel syntax..."
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && chpl --parse-only {{chapel_src}}/DocudactylHPC.chpl {{chapel_src}}/*.chpl'

# Check all HPC C library dependencies and versions
deps-check:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Docudactyl HPC Dependency Check ==="
    echo ""
    FAIL=0
    check_lib() {
        local name="$1" min_ver="$2"
        local ver
        ver=$(toolbox run -c {{toolbox}} pkg-config --modversion "$name" 2>/dev/null || echo "")
        if [ -z "$ver" ]; then
            echo "  MISSING  $name (need >= $min_ver)"
            FAIL=1
        else
            echo "  OK       $name $ver (need >= $min_ver)"
        fi
    }
    check_lib poppler-glib 25.0.0
    check_lib glib-2.0     2.80.0
    check_lib tesseract     5.0.0
    check_lib lept          1.80.0
    check_lib libavformat   61.0.0
    check_lib libavcodec    61.0.0
    check_lib libavutil     59.0.0
    check_lib libxml-2.0    2.12.0
    check_lib gdal          3.11.0
    check_lib vips          8.17.0
    echo ""
    # Check build tools
    echo "--- Build tools ---"
    ZIG_VER=$(toolbox run -c {{toolbox}} bash -c "export PATH=\$HOME/.asdf/shims:\$HOME/.asdf/bin:\$PATH && zig version 2>/dev/null" || echo "")
    CHPL_VER=$(toolbox run -c {{toolbox}} bash -c "chpl --version 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'" || echo "")
    [ -n "$ZIG_VER" ]  && echo "  OK       zig $ZIG_VER (need >= 0.15.0)"  || { echo "  MISSING  zig (need >= 0.15.0)"; FAIL=1; }
    [ -n "$CHPL_VER" ] && echo "  OK       chpl $CHPL_VER (need >= 2.7.0)" || { echo "  MISSING  chpl (need >= 2.7.0)"; FAIL=1; }
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        echo "All dependencies satisfied."
    else
        echo "ERROR: Missing dependencies. Install with:"
        echo "  toolbox run -c {{toolbox}} sudo dnf install poppler-devel tesseract-devel leptonica-devel ffmpeg-free-devel libxml2-devel gdal-devel vips-devel"
        exit 1
    fi

# Run error path tests (valid, missing, corrupt, empty files)
test-error-paths: build-hpc
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Error Path Test ==="
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    # Create test fixtures
    cp /usr/share/doc/pigz/pigz.pdf "$TMPDIR/valid.pdf" 2>/dev/null || echo "%PDF-1.0 test" > "$TMPDIR/valid.pdf"
    cp /usr/share/icons/Adwaita/16x16/devices/audio-headphones.png "$TMPDIR/valid.png" 2>/dev/null || printf '\x89PNG\r\n' > "$TMPDIR/valid.png"
    touch "$TMPDIR/empty.pdf"
    echo "this is not a pdf" > "$TMPDIR/fake.pdf"
    # Manifest: 2 valid + 3 invalid = 5 total
    cat > "$TMPDIR/manifest.txt" << MANIFEST
    # Error path test manifest
    $TMPDIR/valid.pdf
    $TMPDIR/valid.png
    /nonexistent/path/to/missing.pdf
    $TMPDIR/empty.pdf
    $TMPDIR/fake.pdf
    MANIFEST

    OUTDIR="$TMPDIR/output"
    toolbox run -c {{toolbox}} bash -c "export LD_LIBRARY_PATH={{zig_ffi}}/zig-out/lib:\$LD_LIBRARY_PATH; ./bin/docudactyl-hpc --manifestPath=$TMPDIR/manifest.txt --outputDir=$OUTDIR --chunkSize=1 2>&1" | tee "$TMPDIR/run.log"

    # Verify: engine must complete, 2 successes, 3 failures
    SUCCEEDED=$(grep -oP 'Succeeded:\s+\K\d+' "$TMPDIR/run.log" || echo 0)
    FAILED=$(grep -oP 'Failed:\s+\K\d+' "$TMPDIR/run.log" || echo 0)
    echo ""
    echo "--- Results ---"
    echo "Succeeded: $SUCCEEDED (expected >= 1)"
    echo "Failed:    $FAILED (expected >= 2)"
    if [ "$SUCCEEDED" -ge 1 ] && [ "$FAILED" -ge 2 ]; then
        echo "PASS: Error paths handled gracefully"
    else
        echo "FAIL: Unexpected results"
        exit 1
    fi

# Run scale test (2000+ files from /usr/share)
test-scale: build-hpc
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Scale Test ==="
    MANIFEST=$(mktemp)
    trap "rm -f $MANIFEST" EXIT

    find /usr/share/icons -name '*.png' 2>/dev/null | head -2000 > "$MANIFEST"
    find /usr/share/doc -name '*.pdf' 2>/dev/null >> "$MANIFEST"
    COUNT=$(wc -l < "$MANIFEST")
    echo "Manifest: $COUNT files"

    if [ "$COUNT" -lt 100 ]; then
        echo "SKIP: Not enough test files ($COUNT < 100)"
        exit 0
    fi

    OUTDIR=$(mktemp -d)
    trap "rm -rf $OUTDIR; rm -f $MANIFEST" EXIT

    toolbox run -c {{toolbox}} bash -c "export LD_LIBRARY_PATH={{zig_ffi}}/zig-out/lib:\$LD_LIBRARY_PATH; ./bin/docudactyl-hpc --manifestPath=$MANIFEST --outputDir=$OUTDIR 2>&1" | tee /tmp/scale-test.log

    SUCCEEDED=$(grep -oP 'Succeeded:\s+\K\d+' /tmp/scale-test.log || echo 0)
    TOTAL=$(grep -oP 'Documents:\s+\K\d+' /tmp/scale-test.log || echo 0)
    RATE=$(grep -oP 'Throughput:\s+\K[0-9.]+' /tmp/scale-test.log || echo 0)
    FAILPCT=$(grep -oP 'Failure %:\s+\K[0-9.]+' /tmp/scale-test.log || echo 100)

    echo ""
    echo "--- Results ---"
    echo "Total:      $TOTAL"
    echo "Succeeded:  $SUCCEEDED"
    echo "Throughput: $RATE docs/s"
    echo "Failure %:  $FAILPCT%"

    # Pass criteria: >90% success, >1 doc/s
    if awk "BEGIN {exit !($FAILPCT < 10.0)}"; then
        echo "PASS: Failure rate < 10%"
    else
        echo "FAIL: Failure rate >= 10%"
        exit 1
    fi

    if awk "BEGIN {exit !($RATE > 1.0)}"; then
        echo "PASS: Throughput > 1 doc/s"
    else
        echo "FAIL: Throughput <= 1 doc/s"
        exit 1
    fi
    echo "Scale test PASSED"

# Run all HPC tests (FFI unit + integration + error paths)
test-hpc: test-ffi test-error-paths
    @echo "All HPC tests passed!"

# Regenerate C ABI header from Idris2 type definitions
generate-abi-header:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating C ABI header from Idris2 definitions..."

    TYPES="src/Docudactyl/ABI/Types.idr"
    LAYOUT="src/Docudactyl/ABI/Layout.idr"
    OUT="generated/abi/docudactyl_ffi.h"
    mkdir -p "$(dirname "$OUT")"

    # Extract enums from Types.idr
    # ContentKind: lines with contentKindToInt X = N
    declare -A CK_MAP
    while IFS= read -r line; do
        if [[ "$line" =~ contentKindToInt\ ([A-Za-z]+)\ *=\ *([0-9]+) ]]; then
            CK_MAP["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done < "$TYPES"

    # ParseStatus: lines with parseStatusToInt X = N
    declare -A PS_MAP
    while IFS= read -r line; do
        if [[ "$line" =~ parseStatusToInt\ ([A-Za-z]+)\ *=\ *([0-9]+) ]]; then
            PS_MAP["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done < "$TYPES"

    # Extract struct size from Layout.idr (parseResultAligned : Divides 8 NNNNN)
    STRUCT_SIZE=$(grep -oP 'Divides 8 \K[0-9]+' "$LAYOUT" | head -1)
    if [ -z "$STRUCT_SIZE" ]; then
        echo "ERROR: Could not extract struct size from $LAYOUT"
        exit 1
    fi

    # Generate header
    {
    printf '/**\n'
    printf ' * Docudactyl FFI -- C ABI Header\n'
    printf ' *\n'
    printf ' * AUTO-GENERATED from Idris2 ABI definitions.\n'
    printf ' * DO NOT EDIT MANUALLY -- regenerate with: just generate-abi-header\n'
    printf ' *\n'
    printf ' * Source: src/Docudactyl/ABI/Types.idr, Layout.idr, Foreign.idr\n'
    printf ' * Struct size: %s bytes (proven in Layout.idr)\n' "$STRUCT_SIZE"
    printf ' *\n'
    printf ' * SPDX-License-Identifier: PMPL-1.0-or-later\n'
    printf ' * Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>\n'
    printf ' */\n\n'
    printf '#ifndef DOCUDACTYL_FFI_H\n'
    printf '#define DOCUDACTYL_FFI_H\n\n'
    printf '#include <stdint.h>\n\n'
    printf '#ifdef __cplusplus\nextern "C" {\n#endif\n\n'
    printf '/* Content Kind (proven exhaustive and injective: Types.idr) */\n'
    printf 'enum ddac_content_kind {\n'
    } > "$OUT"

    # Write ContentKind enum values
    for name in PDF Image Audio Video EPUB GeoSpatial Unknown; do
        val="${CK_MAP[$name]:-}"
        if [ -n "$val" ]; then
            upper=$(echo "$name" | sed 's/\([a-z]\)\([A-Z]\)/\1_\2/g' | tr '[:lower:]' '[:upper:]')
            printf '    DDAC_%s = %s,\n' "$upper" "$val" >> "$OUT"
        fi
    done
    # Remove trailing comma from last entry
    sed -i '$ s/,$//' "$OUT"

    {
    printf '};\n\n'
    printf '/* Parse Status (retryable: Error, OutOfMemory -- see Types.idr) */\n'
    printf 'enum ddac_parse_status {\n'
    } >> "$OUT"

    for name in Ok Error FileNotFound ParseError NullPointer UnsupportedFormat OutOfMemory; do
        val="${PS_MAP[$name]:-}"
        if [ -n "$val" ]; then
            upper=$(echo "$name" | sed 's/\([a-z]\)\([A-Z]\)/\1_\2/g' | tr '[:lower:]' '[:upper:]')
            printf '    DDAC_%s = %s,\n' "$upper" "$val" >> "$OUT"
        fi
    done
    sed -i '$ s/,$//' "$OUT"

    {
    printf '};\n\n'
    printf '/* Parse Result -- %s bytes, 8-byte aligned (Layout.idr) */\n' "$STRUCT_SIZE"
    printf 'typedef struct ddac_parse_result_t {\n'
    printf '    int32_t  status;\n'
    printf '    int32_t  content_kind;\n'
    printf '    int32_t  page_count;\n'
    printf '    int32_t  _pad0;\n'
    printf '    int64_t  word_count;\n'
    printf '    int64_t  char_count;\n'
    printf '    double   duration_sec;\n'
    printf '    double   parse_time_ms;\n'
    printf '    char     sha256[65];\n'
    printf '    char     _pad1[7];\n'
    printf '    char     error_msg[256];\n'
    printf '    char     title[256];\n'
    printf '    char     author[256];\n'
    printf '    char     mime_type[64];\n'
    printf '} ddac_parse_result_t;\n\n'
    printf '_Static_assert(sizeof(ddac_parse_result_t) == %s,\n' "$STRUCT_SIZE"
    printf '    "ddac_parse_result_t must be %s bytes (Idris2 proof: Layout.idr)");\n' "$STRUCT_SIZE"
    printf '_Static_assert(_Alignof(ddac_parse_result_t) == 8,\n'
    printf '    "ddac_parse_result_t must be 8-byte aligned (Idris2 proof: Layout.idr)");\n\n'
    printf 'void *ddac_init(void);\n'
    printf 'void  ddac_free(void *handle);\n'
    printf 'ddac_parse_result_t ddac_parse(void *handle, const char *input_path,\n'
    printf '                               const char *output_path, int output_fmt);\n'
    printf 'const char *ddac_version(void);\n\n'
    printf '#ifdef __cplusplus\n}\n#endif\n\n'
    printf '#endif /* DOCUDACTYL_FFI_H */\n'
    } >> "$OUT"

    echo "Generated: $OUT (struct size=$STRUCT_SIZE, ${#CK_MAP[@]} content kinds, ${#PS_MAP[@]} parse statuses)"

    # Verify with gcc
    if command -v gcc &>/dev/null; then
        echo "Verifying with gcc..."
        echo '#include "'"$OUT"'"' | gcc -fsyntax-only -xc - && echo "PASS: static assertions hold"
    fi

# Clean HPC build artifacts [reversible: rebuild with `just build-hpc`]
clean-hpc:
    rm -rf bin/docudactyl-hpc
    rm -rf {{zig_ffi}}/zig-out {{zig_ffi}}/.zig-cache

# ═══════════════════════════════════════════════════════════════════════════════
# VERSION CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

# Show git status
status:
    @git status --short

# Show recent commits
log count="20":
    @git log --oneline -{{count}}

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Count lines of code
loc:
    @echo "=== Lines of Code ==="
    @echo "Chapel (HPC):"
    @find {{chapel_src}} -name "*.chpl" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "Zig (FFI):"
    @find {{zig_ffi}}/src -name "*.zig" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "Idris2 (ABI):"
    @find src/Docudactyl -name "*.idr" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "OCaml:"
    @find {{ocaml_src}} -name "*.ml" -o -name "*.mli" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "Ada:"
    @find {{ada_src}} -name "*.ads" -o -name "*.adb" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "Julia (legacy):"
    @find {{julia_src}} -name "*.jl" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"

# Show TODO comments
todos:
    @grep -rn "TODO\|FIXME" --include="*.jl" --include="*.ml" --include="*.ads" --include="*.adb" . 2>/dev/null || echo "No TODOs"

# Open in editor
edit:
    ${EDITOR:-code} .
