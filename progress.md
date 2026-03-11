# Progress Report

## Current Status
Phase 5 of 7: Update lib/session-manager.sh and lib/context-monitor.sh
Status: COMPLETED

## What Was Done This Session
- lib/session-manager.sh: Replaced all 28 bare `jq` calls with `"$TARVOS_JQ"`
- lib/context-monitor.sh: Replaced all 17 bare `jq` calls with `"$TARVOS_JQ"`
- tests/smoke-test.sh: Updated 6 real `jq` calls to `${TARVOS_JQ:-jq}`; mock stubs untouched
- All 19 smoke tests pass

## Immediate Next Task
Begin Phase 6: Add `cmd_update()` function to tarvos.sh. Fetches latest release tag (or accepts --version), downloads fresh TUI binary and tarvos.sh tarball, skips jq re-download unless --force. Add `update` to the case dispatch and --help.

## Key Files for Next Task
- tarvos.sh (add cmd_update function and wire into dispatch + help)

## Gotchas
- None
