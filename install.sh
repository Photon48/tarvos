#!/usr/bin/env bash
set -euo pipefail

# install.sh — symlinks tarvos.sh → /usr/local/bin/tarvos
# Run once after cloning the tarvos repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/tarvos.sh"
LINK="/usr/local/bin/tarvos"

if [[ ! -f "$TARGET" ]]; then
    echo "Error: tarvos.sh not found at ${TARGET}" >&2
    exit 1
fi

chmod +x "$TARGET"

if [[ -e "$LINK" || -L "$LINK" ]]; then
    echo "Removing existing ${LINK}..."
    sudo rm -f "$LINK"
fi

sudo ln -s "$TARGET" "$LINK"
echo "Installed: ${LINK} -> ${TARGET}"

# Install tarvos skill to Claude Code personal skills directory
SKILLS_DIR="${HOME}/.claude/skills/tarvos-skill"
mkdir -p "$SKILLS_DIR"
cp "${SCRIPT_DIR}/tarvos-skill/SKILL.md" "$SKILLS_DIR/SKILL.md"
echo "Installed skill: ${SKILLS_DIR}/SKILL.md"

echo "Run \`tarvos --help\` to get started."
