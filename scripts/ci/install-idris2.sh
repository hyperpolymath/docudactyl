#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# Official v0.8.0, pinned to its commit. No sudo: bootstrap and install must
# agree on PREFIX, otherwise sudo installs under /root and CI cannot find it.
[[ ${IDRIS2_VERSION:-0.8.0} == 0.8.0 ]] || { echo 'Update the Idris2 commit and cache key together' >&2; exit 1; }
revision=15a3e4e70843f7a34100f6470c04b791330788df
prefix="$HOME/.local/idris2"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/src"
git -C "$tmp/src" remote add origin https://github.com/idris-lang/Idris2.git
git -C "$tmp/src" fetch --depth 1 origin "$revision"
git -C "$tmp/src" checkout --detach FETCH_HEAD
[[ $(git -C "$tmp/src" rev-parse HEAD) == "$revision" ]]
make -C "$tmp/src" bootstrap SCHEME=chezscheme PREFIX="$prefix"
make -C "$tmp/src" install PREFIX="$prefix"
"$prefix/bin/idris2" --version
