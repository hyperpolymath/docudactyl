;; SPDX-License-Identifier: PMPL-1.0-or-later
(neurosym
  (metadata
    (version "0.4.0")
    (last-updated "2026-02-21"))
  (verification-layers
    (layer "idris2-abi"
      (type formal-proof)
      (scope "Struct layout, alignment, enum exhaustiveness, type safety")
      (files "src/Docudactyl/ABI/Types.idr" "src/Docudactyl/ABI/Layout.idr" "src/Docudactyl/ABI/Foreign.idr")
      (guarantees
        "ParseResult is exactly 952 bytes on LP64"
        "MlResult is exactly 48 bytes, 8-byte aligned"
        "CryptoCaps is exactly 16 bytes, 1-byte aligned"
        "All enum conversions are injective (no collisions)"
        "All FFI declarations match C header signatures"))
    (layer "zig-compile-time"
      (type static-analysis)
      (scope "Comptime struct validation, overflow checks, null safety")
      (files "ffi/zig/src/docudactyl_ffi.zig")
      (guarantees
        "comptime assert on struct sizes matching Idris2 proofs"
        "Null pointer checks on all handle operations"
        "No undefined behaviour in release builds"))
    (layer "c-header-generation"
      (type code-generation)
      (scope "Auto-generated C header from Justfile recipe")
      (files "generated/abi/docudactyl_ffi.h")
      (guarantees
        "Header regenerated from Zig source, not hand-maintained"
        "51 function declarations matching all ddac_* exports"))
    (layer "integration-tests"
      (type runtime-verification)
      (scope "C ABI compliance, null safety, struct sizes, subsystem lifecycle")
      (files "ffi/zig/test/integration_test.zig")
      (guarantees
        "40+ tests covering all subsystem APIs"
        "Struct size assertions match Idris2 proofs"
        "Null-handle safety on all free/setter functions"))))
