#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# Fast checks without Poppler/GDAL/etc. Explicit list: never silently skip a
# module after an import changes. The full `zig build test` remains mandatory.
for module in capnp conduit dragonfly entity_graph evasion_detect \
  financial_extract flight_log gpu_ocr hw_crypto investigator_summary \
  legal_ner ml_inference prefetch quality_stats speaker_id; do
  zig test "ffi/zig/src/$module.zig" -lc
done
