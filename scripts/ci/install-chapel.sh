#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# Official Ubuntu 24.04 amd64 package. The linux64 tarball is not a release asset.
[[ ${CHAPEL_VERSION:-2.8.0} == 2.8.0 ]] || { echo 'Update the package digest when changing Chapel' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
package=chapel-2.8.0-1.ubuntu24.amd64.deb
curl --fail --location --retry 3 "https://github.com/chapel-lang/chapel/releases/download/2.8.0/$package" -o "$tmp/$package"
echo "278e1111b8d8b8c3d45d8c2b0976bea21f68509a15847d513cf68113c2f4d59a  $tmp/$package" | sha256sum --check --strict
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends "$tmp/$package"
chpl --version
