#!/usr/bin/env bash
set -euo pipefail

# install.sh — standalone Tarvos installer
# Usage: curl -fsSL https://raw.githubusercontent.com/Photon48/tarvos/main/install.sh | bash

TARVOS_REPO="Photon48/tarvos"

# ─── Pinned versions (updated by CI on each release) ─────────────────────────
TARVOS_VERSION="v0.1.0"
JQ_VERSION="jq-1.8.1"

# ─── Platform detection ───────────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"    # darwin / linux
ARCH="$(uname -m)"                                # arm64 / x86_64 / aarch64

case "$OS/$ARCH" in
  darwin/arm64)   TUI_PLATFORM="darwin-arm64"; JQ_PLATFORM="macos-arm64"  ;;
  darwin/x86_64)  TUI_PLATFORM="darwin-x64";   JQ_PLATFORM="macos-amd64"  ;;
  linux/x86_64)   TUI_PLATFORM="linux-x64";    JQ_PLATFORM="linux-amd64"  ;;
  linux/aarch64)  TUI_PLATFORM="linux-arm64";  JQ_PLATFORM="linux-arm64"  ;;
  *) echo "Unsupported platform: $OS/$ARCH" >&2; exit 1 ;;
esac

# ─── Directories ──────────────────────────────────────────────────────────────
TARVOS_DATA_DIR="${TARVOS_DATA_DIR:-${HOME}/.local/share/tarvos}"
TARVOS_BIN_DIR="${TARVOS_DATA_DIR}/bin"
mkdir -p "$TARVOS_BIN_DIR"

GITHUB_RELEASES="https://github.com/${TARVOS_REPO}/releases/download/${TARVOS_VERSION}"

echo "Installing Tarvos ${TARVOS_VERSION} (${TUI_PLATFORM})..."

# ─── Download jq (idempotent — skip if already present) ──────────────────────
JQ_BIN="${TARVOS_BIN_DIR}/jq"
if [[ ! -x "$JQ_BIN" ]]; then
  echo "Downloading jq ${JQ_VERSION}..."
  curl -fsSL "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-${JQ_PLATFORM}" \
    -o "$JQ_BIN"
  chmod +x "$JQ_BIN"
  # Remove macOS quarantine attribute to avoid Gatekeeper prompt
  if [[ "$OS" == "darwin" ]]; then
    xattr -dr com.apple.quarantine "$JQ_BIN" 2>/dev/null || true
  fi
else
  echo "jq already installed, skipping."
fi

# ─── Download TUI binary (always refresh to get the correct version) ──────────
TUI_BIN="${TARVOS_BIN_DIR}/tui"
echo "Downloading TUI binary (tui-${TUI_PLATFORM})..."
curl -fsSL "${GITHUB_RELEASES}/tui-${TUI_PLATFORM}" -o "$TUI_BIN"
chmod +x "$TUI_BIN"
# Remove macOS quarantine attribute to avoid Gatekeeper prompt
if [[ "$OS" == "darwin" ]]; then
  xattr -dr com.apple.quarantine "$TUI_BIN" 2>/dev/null || true
fi

# ─── Download and extract tarvos release tarball ─────────────────────────────
TARBALL_NAME="tarvos-${TARVOS_VERSION}.tar.gz"
echo "Downloading ${TARBALL_NAME}..."
TARBALL_TMP="$(mktemp /tmp/tarvos-XXXXXX.tar.gz)"
curl -fsSL "${GITHUB_RELEASES}/${TARBALL_NAME}" -o "$TARBALL_TMP"

# Extract into data dir (tarvos.sh + lib/ + tarvos-skill/)
tar -xzf "$TARBALL_TMP" -C "$TARVOS_DATA_DIR" --strip-components=1
rm -f "$TARBALL_TMP"

chmod +x "${TARVOS_DATA_DIR}/tarvos.sh"

# ─── Symlink to /usr/local/bin/tarvos ────────────────────────────────────────
LINK="/usr/local/bin/tarvos"
if [[ -e "$LINK" || -L "$LINK" ]]; then
  sudo rm -f "$LINK"
fi
sudo ln -sf "${TARVOS_DATA_DIR}/tarvos.sh" "$LINK"
echo "Installed: ${LINK} -> ${TARVOS_DATA_DIR}/tarvos.sh"

# ─── Install Claude skill ─────────────────────────────────────────────────────
SKILLS_DIR="${HOME}/.claude/skills/tarvos-skill"
mkdir -p "$SKILLS_DIR"
if [[ -f "${TARVOS_DATA_DIR}/tarvos-skill/SKILL.md" ]]; then
  cp "${TARVOS_DATA_DIR}/tarvos-skill/SKILL.md" "${SKILLS_DIR}/SKILL.md"
  echo "Installed skill: ${SKILLS_DIR}/SKILL.md"
fi

# ─── Check for claude CLI ─────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo ""
  echo "Warning: 'claude' CLI not found." >&2
  echo "Install it from: https://docs.anthropic.com/en/docs/claude-code" >&2
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "Tarvos ${TARVOS_VERSION} installed successfully!"
echo "Run \`tarvos --help\` to get started."
