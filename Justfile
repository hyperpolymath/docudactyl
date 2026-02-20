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
version := "0.1.0"
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

# Build all components
build: build-julia build-ocaml build-ada
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
    rm -rf target _build dist

# Deep clean including caches [reversible: rebuild]
clean-all: clean
    rm -rf .cache .tmp
    cd {{julia_src}} && rm -rf Manifest.toml

# ═══════════════════════════════════════════════════════════════════════════════
# TEST & QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run all tests
test: test-julia test-ocaml
    @echo "All tests passed!"

# Run Julia tests
test-julia:
    @echo "Running Julia tests..."
    cd {{julia_src}} && julia --project=. -e 'using Pkg; Pkg.test()'

# Run OCaml tests
test-ocaml:
    @echo "Running OCaml tests..."
    cd {{ocaml_src}} && dune runtest

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
    cat > docs/man/{{project}}.1 << EOF
.TH RSR-TEMPLATE-REPO 1 "$(date +%Y-%m-%d)" "{{version}}" "RSR Template Manual"
.SH NAME
{{project}} \- RSR standard repository template
.SH SYNOPSIS
.B just
[recipe] [args...]
.SH DESCRIPTION
Canonical template for RSR (Rhodium Standard Repository) projects.
.SH AUTHOR
Hyperpolymath <hyperpolymath@proton.me>
EOF
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
    @mkdir -p .git/hooks
    @cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
just fmt-check || exit 1
just lint || exit 1
EOF
    @chmod +x .git/hooks/pre-commit
    @echo "Git hooks installed"

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
toolbox := "fedora-toolbox-43"

# Build the Zig FFI shared/static libraries
build-ffi:
    @echo "Building Zig FFI (poppler, tesseract, ffmpeg, libxml2, gdal, vips)..."
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && cd {{zig_ffi}} && zig build -Doptimize=ReleaseFast'

# Build Chapel HPC binary (depends on Zig FFI)
build-chapel: build-ffi
    @echo "Building Chapel HPC engine..."
    @mkdir -p bin
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && \
         chpl {{chapel_src}}/DocudactylHPC.chpl \
              {{chapel_src}}/Config.chpl \
              {{chapel_src}}/ContentType.chpl \
              {{chapel_src}}/FFIBridge.chpl \
              {{chapel_src}}/ManifestLoader.chpl \
              {{chapel_src}}/FaultHandler.chpl \
              {{chapel_src}}/ProgressReporter.chpl \
              {{chapel_src}}/ShardedOutput.chpl \
              {{chapel_src}}/ResultAggregator.chpl \
              -o bin/docudactyl-hpc \
              -L{{zig_ffi}}/zig-out/lib -ldocudactyl_ffi \
              --fast'

# Build complete HPC stack (FFI + Chapel)
build-hpc: build-ffi build-chapel
    @echo "HPC stack built: bin/docudactyl-hpc"

# Run HPC engine on a manifest (single locale)
run-hpc manifest *args:
    toolbox run -c {{toolbox}} bash -c 'export LD_LIBRARY_PATH="{{zig_ffi}}/zig-out/lib:$$LD_LIBRARY_PATH" && bin/docudactyl-hpc --manifestPath={{manifest}} {{args}}'

# Run HPC engine on a cluster (multiple locales)
run-hpc-cluster manifest locales="64" *args:
    toolbox run -c {{toolbox}} bash -c 'export LD_LIBRARY_PATH="{{zig_ffi}}/zig-out/lib:$$LD_LIBRARY_PATH" && bin/docudactyl-hpc --manifestPath={{manifest}} -nl {{locales}} {{args}}'

# Generate a manifest file from a directory of documents
generate-manifest dir output="manifest.txt":
    find {{dir}} -type f \( -name '*.pdf' -o -name '*.jpg' -o -name '*.png' \
         -o -name '*.tiff' -o -name '*.mp3' -o -name '*.wav' -o -name '*.mp4' \
         -o -name '*.epub' -o -name '*.shp' \) > {{output}}
    @echo "Manifest written to {{output}} ($$(wc -l < {{output}}) files)"

# Run Zig FFI integration tests
test-ffi:
    @echo "Running Zig FFI tests..."
    toolbox run -c {{toolbox}} bash -c 'export PATH="$$HOME/.asdf/shims:$$HOME/.asdf/bin:$$PATH" && cd {{zig_ffi}} && zig build test'

# Check Chapel parse validity
check-chapel:
    @echo "Checking Chapel syntax..."
    toolbox run -c {{toolbox}} chpl --parse-only {{chapel_src}}/DocudactylHPC.chpl {{chapel_src}}/*.chpl

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
    @echo "Julia:"
    @find {{julia_src}} -name "*.jl" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "OCaml:"
    @find {{ocaml_src}} -name "*.ml" -o -name "*.mli" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"
    @echo "Ada:"
    @find {{ada_src}} -name "*.ads" -o -name "*.adb" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"

# Show TODO comments
todos:
    @grep -rn "TODO\|FIXME" --include="*.jl" --include="*.ml" --include="*.ads" --include="*.adb" . 2>/dev/null || echo "No TODOs"

# Open in editor
edit:
    ${EDITOR:-code} .
