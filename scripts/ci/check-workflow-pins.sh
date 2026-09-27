#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# Check the actual ref, not a trailing '# SHA' comment. Local actions are
# allowed; container actions must be content-addressed too.
status=0
if (( $# == 0 )); then set -- .github/workflows; fi
for file in "$@"; do
  if [[ -d "$file" ]]; then
    bash "$0" "$file"/*.yml "$file"/*.yaml || status=1
    continue
  fi
  [[ -f "$file" ]] || continue
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]-]*uses:[[:space:]]*([^[:space:]#]+) ]]; then
      ref=${BASH_REMATCH[1]}
      ref=${ref//\'/}
      ref=${ref//\"/}
      if [[ $ref == ./* || $ref =~ ^[^@]+@[a-fA-F0-9]{40}$ || $ref =~ ^docker://[^@]+@sha256:[a-fA-F0-9]{64}$ ]]; then
        continue
      fi
      echo "ERROR: $file: unpinned action $ref" >&2
      status=1
    fi
  done < "$file"
done
exit "$status"
