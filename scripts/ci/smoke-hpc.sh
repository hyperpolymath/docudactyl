#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# A generated, deterministic WAV avoids dependencies on runner icons/documents.
# PCM: mono, 8000 Hz, 16-bit, eight samples. Audio parsing requires no OCR models.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'RIFF\x34\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00data\x10\x00\x00\x00' > "$tmp/tone.wav"
printf '\0%.0s' {1..16} >> "$tmp/tone.wav"
printf '%s\n' "$tmp/tone.wav" > "$tmp/manifest.txt"
export LD_LIBRARY_PATH="$PWD/ffi/zig/zig-out/lib:${LD_LIBRARY_PATH:-}"
# Both loading strategies must actually parse the fixture, not merely exit zero.
for mode in shared broadcast; do
  bin/docudactyl-hpc --manifestPath="$tmp/manifest.txt" \
    --manifestMode="$mode" --outputDir="$tmp/$mode" --chunkSize=1
  test -s "$tmp/$mode/run-report.scm"
  jq -e '.summary | .totalDocs == 1 and .succeeded == 1 and .failed == 0' \
    "$tmp/$mode/run-report.json"
done
