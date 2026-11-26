#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Planted fixtures for docs-ingest: build the binary, ingest the fixture
# repo, and compare the bundle byte for byte with the expected output.
set -euo pipefail
cd "$(dirname "$0")/../.."
fx=tests/fixtures/docs-ingest
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
zig build-exe ffi/zig/src/docs_ingest_cli.zig --name docs-ingest \
  -femit-bin="$out/docs-ingest" --cache-dir "$out/cache" --global-cache-dir "$out/gcache"
"$out/docs-ingest" --repo hyperpolymath/fixture \
  --rev 0123456789abcdef0123456789abcdef01234567 \
  --root "$fx/repo" --files "$fx/files.txt" > "$out/bundle.json"
diff -u "$fx/expected.json" "$out/bundle.json"
# Error paths: bad rev and unsafe list entries must exit 2.
set +e
"$out/docs-ingest" --repo a/b --rev nothex --root "$fx/repo" --files "$fx/files.txt" 2>/dev/null; r1=$?
printf '../etc/passwd\n' > "$out/bad.txt"
"$out/docs-ingest" --repo a/b --rev 0123456789abcdef0123456789abcdef01234567 \
  --root "$fx/repo" --files "$out/bad.txt" 2>/dev/null; r2=$?
set -e
[ "$r1" = 2 ] && [ "$r2" = 2 ] || { echo "expected exit 2, got $r1 and $r2" >&2; exit 1; }
echo "docs-ingest fixtures: OK"
