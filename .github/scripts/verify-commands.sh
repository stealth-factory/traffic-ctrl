#!/usr/bin/env bash
# Verify both command names in a build directory.
#
# Usage: verify-commands.sh <bin-dir> <arch> [expected-version]
#
# The self-hosted Macs are Apple silicon. Intel builds are cross-compiled and
# run under Rosetta when it is installed; without Rosetta only their
# architecture is checked.
set -euo pipefail

bin_dir="$1"
arch="$2"
expected_version="${3:-}"
run=()

if [[ "$(uname -s)" == Darwin ]]; then
  for command in traffic-ctrl trctrl; do
    actual="$(lipo -archs "${bin_dir}/${command}")"
    if [[ "$actual" != "$arch" ]]; then
      echo "${command} is built for ${actual}, expected ${arch}" >&2
      exit 1
    fi
  done
  if [[ "$arch" == x86_64 && "$(uname -m)" == arm64 ]]; then
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
      echo "::notice::Rosetta is not installed; checked the x86_64 architecture without running the commands."
      exit 0
    fi
    run=(arch -x86_64)
  fi
fi

${run[@]+"${run[@]}"} "${bin_dir}/traffic-ctrl" --help >/dev/null
${run[@]+"${run[@]}"} "${bin_dir}/trctrl" --help >/dev/null

version="$(${run[@]+"${run[@]}"} "${bin_dir}/traffic-ctrl" --version)"
echo "$version" | grep -Eq '^traffic-ctrl [0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'
test "$version" = "$(${run[@]+"${run[@]}"} "${bin_dir}/trctrl" --version)"
if [[ -n "$expected_version" ]]; then
  test "$version" = "traffic-ctrl ${expected_version}"
fi
