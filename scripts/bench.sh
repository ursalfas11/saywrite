#!/usr/bin/env bash
# Measures release-to-text latency with the real pipeline on the sample recordings.
# Usage: scripts/bench.sh [--no-ai]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product Saywrite >/dev/null
BIN="$(swift build -c release --show-bin-path)/Saywrite"
for sample in scripts/samples/*.wav; do
  for style in casual neutral formal; do
    echo "== $(basename "$sample") / $style"
    "$BIN" --selftest "$sample" "$style" "$@" | grep -E "final|latency"
  done
done
