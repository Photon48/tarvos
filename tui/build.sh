#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-bun-darwin-arm64}"
bun build src/index.tsx --compile --target="$TARGET" --outfile "dist/tui-${TARGET#bun-}" --minify
echo "Built: dist/tui-${TARGET#bun-}"
