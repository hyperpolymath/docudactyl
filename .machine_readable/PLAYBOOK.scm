;; SPDX-License-Identifier: PMPL-1.0-or-later
(playbook
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-21"))
  (operations
    (op "build"
      (description "Build the HPC binary from Zig FFI + Chapel source")
      (command "just build-hpc")
      (prerequisites "zig >= 0.13, chapel >= 2.3")
      (artifacts "bin/docudactyl-hpc" "ffi/zig/zig-out/lib/libdocudactyl_ffi.so"))
    (op "test"
      (description "Run all tests: FFI integration + error paths + scale")
      (command "just test-hpc")
      (prerequisites "build-hpc must succeed first"))
    (op "container-build"
      (description "Build OCI container image for cluster deployment")
      (command "podman build -f deploy/Containerfile -t docudactyl-hpc .")
      (prerequisites "Podman installed"))
    (op "cluster-submit"
      (description "Submit Slurm job for HPC cluster execution")
      (command "sbatch deploy/slurm-docudactyl.sh")
      (prerequisites "Slurm cluster with GASNet/IBV, manifest at /data/manifest.txt"))
    (op "generate-manifest"
      (description "Generate manifest file from a directory of documents")
      (command "just generate-manifest /path/to/documents manifest.txt"))
    (op "verify-abi"
      (description "Verify ABI consistency across Idris2, Zig, and C header")
      (command "just check-abi")
      (prerequisites "idris2 >= 0.8.0"))
    (op "generate-header"
      (description "Regenerate C header from Zig FFI exports")
      (command "just generate-abi-header"))
    (op "deps-check"
      (description "Verify all runtime and build dependencies are available")
      (command "just deps-check")))
  (runbook
    (scenario "fresh-cluster-deployment"
      (steps
        "1. just deps-check — verify all dependencies"
        "2. just build-hpc — build Zig FFI + Chapel binary"
        "3. just test-hpc — run all tests"
        "4. podman build -f deploy/Containerfile -t docudactyl-hpc ."
        "5. podman push docudactyl-hpc registry.example.com/docudactyl-hpc"
        "6. Edit deploy/slurm-docudactyl.sh: adjust MANIFEST, nodes, partition"
        "7. sbatch deploy/slurm-docudactyl.sh"))
    (scenario "incremental-reprocessing"
      (steps
        "1. Generate manifest of new/changed files only"
        "2. Set MANIFEST_MODE=shared, resume=true in Slurm script"
        "3. sbatch deploy/slurm-docudactyl.sh"
        "4. Checkpoint resume will skip already-processed documents"))
    (scenario "adding-new-content-type"
      (steps
        "1. Add ContentKind variant in src/Docudactyl/ABI/Types.idr"
        "2. Add detection in ffi/zig/src/conduit.zig"
        "3. Add parser in ffi/zig/src/docudactyl_ffi.zig"
        "4. Add dispatch in src/chapel/ContentType.chpl"
        "5. Update generated/abi/docudactyl_ffi.h"
        "6. Add integration test in ffi/zig/test/integration_test.zig"
        "7. Update STATE.scm component descriptions"))))
