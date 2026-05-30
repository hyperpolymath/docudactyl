// Docudactyl HPC — FFI Smoke Test (decoupled from the metalayer)
//
// Minimal Chapel program that exercises the C ABI via `require` +
// `extern record` WITHOUT pulling in the full DocudactylHPC metalayer.
// Verifies the FFI ABI compiles + links without depending on the full
// DocudactylHPC metalayer. Per docudactyl#29 / the echidna#146 pattern.
//
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

use FFIBridge;
use CTypes;

proc main() {
  // ── Step 1: ddac_version() ────────────────────────────────────────
  const ver = ddac_version();
  if ver == nil {
    writeln("[smoke] FAIL: ddac_version returned nil");
    exit(1);
  }
  writeln("[smoke] ddac_version: ",
          string.createCopyingBuffer(ver:c_ptrConst(c_char)));

  // ── Step 2: ddac_crypto_sha256_name() ─────────────────────────────
  const cryptoName = ddac_crypto_sha256_name();
  if cryptoName == nil {
    writeln("[smoke] FAIL: ddac_crypto_sha256_name returned nil");
    exit(1);
  }
  writeln("[smoke] ddac_crypto_sha256_name: ",
          string.createCopyingBuffer(cryptoName:c_ptrConst(c_char)));

  // ── Step 3: ddac_init() / ddac_free() ─────────────────────────────
  var handle = ddac_init();
  if handle == nil {
    writeln("[smoke] FAIL: ddac_init returned nil handle");
    exit(1);
  }
  writeln("[smoke] init ok");
  ddac_free(handle);

  writeln("[smoke] PASS");
}
