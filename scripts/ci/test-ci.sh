#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for ref in 'owner/action@v1 # 0123456789012345678901234567890123456789' 'owner/action@main' 'docker://image:latest'; do
  printf '      - uses: %s\n' "$ref" > "$tmp/bad.yml"
  if bash "$root/scripts/ci/check-workflow-pins.sh" "$tmp/bad.yml"; then
    echo "FAIL: accepted unpinned ref: $ref" >&2; exit 1
  fi
done
printf '%s\n' '      - uses: owner/action@0123456789012345678901234567890123456789 # v1' \
  '    uses: ./local-action' > "$tmp/good.yml"
bash "$root/scripts/ci/check-workflow-pins.sh" "$tmp/good.yml"
# Prove the smoke harness rejects zero-success reports, independently of the
# expensive native build. This mock does NOT validate the HPC implementation.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docudactyl-hpc" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    --manifestPath=*) manifest=${arg#*=} ;;
    --outputDir=*) output=${arg#*=} ;;
  esac
done
fixture=$(cat "$manifest")
[[ $(wc -c < "$fixture") == 60 ]]
[[ $(head -c 4 "$fixture") == RIFF ]]
mkdir -p "$output"
printf '(report)\n' > "$output/run-report.scm"
printf '{"summary":{"totalDocs":1,"succeeded":%s,"failed":%s}}\n' \
  "${MOCK_SUCCESS:-1}" "$((1 - ${MOCK_SUCCESS:-1}))" > "$output/run-report.json"
MOCK
chmod +x "$tmp/bin/docudactyl-hpc"
(cd "$tmp" && bash "$root/scripts/ci/smoke-hpc.sh")
if (cd "$tmp" && MOCK_SUCCESS=0 bash "$root/scripts/ci/smoke-hpc.sh"); then
  echo 'FAIL: smoke accepted zero successful documents' >&2; exit 1
fi
echo 'PASS: CI harness regression tests'
