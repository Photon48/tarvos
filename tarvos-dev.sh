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

# Resolve the real location of this script (follow symlinks)
_DEV_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_DEV_SOURCE" ]]; do
    _DEV_SOURCE="$(readlink "$_DEV_SOURCE")"
done
REPO_DIR="$(cd "$(dirname "$_DEV_SOURCE")" && pwd)"
unset _DEV_SOURCE

# Make it obvious you are in dev mode, not hitting production
echo "[tarvos-dev] repo: $REPO_DIR" >&2
echo "[tarvos-dev] branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo 'unknown')" >&2

# Require a local TUI build — never fall back to production binary
_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
_ARCH="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')"
_LOCAL_TUI="${REPO_DIR}/tui/dist/tui-${_OS}-${_ARCH}"

if [[ -z "${TUI_BIN_PATH:-}" ]]; then
    if [[ ! -x "$_LOCAL_TUI" ]]; then
        echo "[tarvos-dev] ERROR: no local TUI binary found for ${_OS}-${_ARCH}" >&2
        echo "[tarvos-dev] Build it first:" >&2
        echo "  cd ${REPO_DIR}/tui && bun run build:${_OS}-${_ARCH}" >&2
        echo "  # or to auto-rebuild on every save:" >&2
        echo "  cd ${REPO_DIR}/tui && bun run watch" >&2
        exit 1
    fi
    export TUI_BIN_PATH="$_LOCAL_TUI"
    echo "[tarvos-dev] TUI: local build (${_OS}-${_ARCH})" >&2
fi

exec bash "$REPO_DIR/tarvos.sh" "$@"
