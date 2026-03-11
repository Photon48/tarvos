#!/usr/bin/env bash
# tarvos-dev — run the LOCAL repo's tarvos.sh (development mode)
#
# This bypasses the production install at ~/.local/share/tarvos/ entirely.
# Use this when testing changes in your local git repo.
#
# Usage: ./tarvos-dev.sh <subcommand> [args...]
#    or: tarvos-dev <subcommand> [args...]  (if symlinked onto PATH)
#
# To put it on PATH permanently:
#   ln -sf "$PWD/tarvos-dev.sh" ~/bin/tarvos-dev
#
# To test a local TUI build at the same time:
#   TUI_BIN_PATH="$PWD/tui/dist/tui-darwin-arm64" ./tarvos-dev.sh tui

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Make it obvious you are in dev mode, not hitting production
echo "[tarvos-dev] repo: $REPO_DIR" >&2
echo "[tarvos-dev] branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo 'unknown')" >&2

exec bash "$REPO_DIR/tarvos.sh" "$@"
