# Progress Report

## Current Status
Phase 3 of 7: New curl-based install script
Status: COMPLETED

## What Was Done This Session
- install.sh: Rewrote as standalone curl-piped installer (platform detection, downloads jq + TUI binary + tarball, symlinks, skill install)
- .github/workflows/release.yml: Added tarball build step that packages tarvos.sh + lib/ + tarvos-skill/ as tarvos-$VERSION.tar.gz and uploads it as a release asset

## Immediate Next Task
Begin Phase 4: Update tarvos.sh — (4a) replace bun resolution block with dev comment, (4b) add jq+TUI binary resolution block, (4c) update TUI invocations, (4d) remove jq prerequisite guards.

## Key Files for Next Task
- tarvos.sh (multiple edits: lines ~25-30 for bun block, add resolution block after, update TUI invocations at ~1089 and ~1761, remove jq guards in cmd_init/begin/continue/migrate)

## Gotchas
- tarvos.sh uses `exec "$_TUI_BIN"` pattern — both TUI call sites need the guard + exec replacement
- jq guards use `command -v jq` — search for these in cmd_init, cmd_begin, cmd_continue, cmd_migrate
