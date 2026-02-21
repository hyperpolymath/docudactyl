;; SPDX-License-Identifier: PMPL-1.0-or-later
(meta
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-21"))
  (project-info
    (type monorepo-child)
    (parent "bofig")
    (languages (chapel zig idris2 ocaml ada julia))
    (license "PMPL-1.0-or-later")
    (author "Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>"))
  (architecture-decisions
    (adr "001-chapel-over-julia"
      (status accepted)
      (date "2026-02-15")
      (decision "Chapel replaces Julia for HPC orchestration")
      (rationale "Chapel provides native multi-locale distributed execution with GASNet, dynamic load balancing, and zero-runtime overhead. Julia's GC pauses and startup latency are unacceptable at 170M document scale"))
    (adr "002-zig-ffi-not-direct-c"
      (status accepted)
      (date "2026-02-15")
      (decision "Zig thin FFI wrapper around C libraries instead of direct Chapel extern")
      (rationale "Zig provides unified error handling, memory safety, and cross-compilation. Compiles to identical machine code as direct C calls with zero overhead"))
    (adr "003-idris2-abi-proofs"
      (status accepted)
      (date "2026-02-15")
      (decision "Idris2 dependent types for ABI correctness proofs")
      (rationale "Formal verification of struct layout, alignment, and enum exhaustiveness prevents ABI drift between Chapel, Zig, and C layers"))
    (adr "004-two-level-cache"
      (status accepted)
      (date "2026-02-18")
      (decision "L1 LMDB per-locale + L2 Dragonfly cross-locale caching")
      (rationale "L1 handles repeat access within a locale with zero-copy mmap. L2 handles cross-locale dedup and warm restarts. Dragonfly chosen over Redis for 25x throughput on multi-core"))
    (adr "005-dlopen-optional-deps"
      (status accepted)
      (date "2026-02-18")
      (decision "Runtime dlopen for ONNX, PaddleOCR, CUDA instead of link-time dependency")
      (rationale "Allows the binary to run on any machine. GPU/ML features activate when libraries are present, degrade gracefully when absent")))
  (development-practices
    (build-system "just (Justfile)")
    (testing "Zig integration tests against C ABI + Chapel error-path and scale tests")
    (ci "GitHub Actions with RSR standard workflows")
    (container "Podman + Containerfile (Wolfi runtime base)")
    (deployment "Slurm HPC cluster with GASNet/IBV")))
