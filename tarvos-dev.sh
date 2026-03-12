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
# TUI auto-detection: if tui/dist/ contains a binary for the current platform,
# it is used automatically — no TUI_BIN_PATH env var needed.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Make it obvious you are in dev mode, not hitting production
echo "[tarvos-dev] repo: $REPO_DIR" >&2
echo "[tarvos-dev] branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo 'unknown')" >&2

# Auto-detect local TUI build for this platform and use it if present
if [[ -z "${TUI_BIN_PATH:-}" ]]; then
    _OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    _ARCH="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')"
    _LOCAL_TUI="${REPO_DIR}/tui/dist/tui-${_OS}-${_ARCH}"
    if [[ -x "$_LOCAL_TUI" ]]; then
        export TUI_BIN_PATH="$_LOCAL_TUI"
        echo "[tarvos-dev] TUI: local build (${_OS}-${_ARCH})" >&2
    fi
fi

exec bash "$REPO_DIR/tarvos.sh" "$@"
