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
# A symlink that leads outside --root, and a document that is not UTF-8.
mkdir -p "$out/esc/root"
printf '# Private\n' > "$out/esc/private.md"
ln -s ../private.md "$out/esc/root/README.md"
printf 'README.md\n' > "$out/esc/files.txt"
"$out/docs-ingest" --repo a/b --rev 0123456789abcdef0123456789abcdef01234567 \
  --root "$out/esc/root" --files "$out/esc/files.txt" > /dev/null 2>&1; r3=$?
mkdir -p "$out/utf/root"
printf '# Caf\xe9\n' > "$out/utf/root/README.md"
"$out/docs-ingest" --repo a/b --rev 0123456789abcdef0123456789abcdef01234567 \
  --root "$out/utf/root" --files "$out/esc/files.txt" > /dev/null 2>&1; r4=$?
set -e
for r in "$r1" "$r2" "$r3" "$r4"; do
  [ "$r" = 2 ] || { echo "expected exit 2, got $r1 $r2 $r3 $r4" >&2; exit 1; }
done
echo "docs-ingest fixtures: OK"
