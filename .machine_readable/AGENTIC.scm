;; SPDX-License-Identifier: PMPL-1.0-or-later
(agentic
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-21"))
  (constraints
    (constraint "no-unsafe-abi"
      (description "Never use believe_me, assert_total, or Admitted in Idris2 ABI proofs")
      (severity critical))
    (constraint "no-zig-panic"
      (description "Never use @panic in Zig release builds — return error codes via C ABI")
      (severity critical))
    (constraint "no-link-time-optional"
      (description "ONNX Runtime, PaddleOCR, CUDA must be loaded via dlopen, never linked at compile time")
      (severity high))
    (constraint "flat-c-structs"
      (description "All FFI boundary types must be flat C structs — no pointers to managed memory, no variable-length fields")
      (severity high))
    (constraint "author-attribution"
      (description "Author: Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>. Never 'Hyperpolymath' as author name, never proton.me email")
      (severity high))
    (constraint "containerfile-not-dockerfile"
      (description "Use 'Containerfile' naming and Podman runtime, never 'Dockerfile' or Docker")
      (severity medium)))
  (automation
    (bot "rhodibot" (role "dependency updates"))
    (bot "finishbot" (role "completion tracking"))
    (bot "seambot" (role "integration validation")))
  (interaction-patterns
    (pattern "read-state-first"
      (description "Always read .machine_readable/STATE.scm before making changes"))
    (pattern "update-state-after"
      (description "Update STATE.scm completion and component status after significant changes"))
    (pattern "verify-abi-consistency"
      (description "After changing Zig FFI signatures, verify Idris2 Foreign.idr and generated C header match"))))
