# Progress Report

## Current Status
Phase 6 of 7: Add `tarvos update` command
Status: COMPLETED

## What Was Done This Session
- tarvos.sh: Added `usage_update()` with --version, --force, -h flags documented
- tarvos.sh: Added `cmd_update()` — fetches latest tag from GitHub API (or uses --version), downloads fresh TUI binary + tarvos tarball, skips jq unless --force, updates Claude skill
- tarvos.sh: Wired `update` into case dispatch in `main()` and listed in `usage_root()`
- All 19 smoke tests pass

## Immediate Next Task
Begin Phase 7: Update README.md — change prerequisites to just `claude` CLI, update quickstart to curl install, add Development section with bun rebuild instructions.

## Key Files for Next Task
- README.md

## Gotchas
- None
