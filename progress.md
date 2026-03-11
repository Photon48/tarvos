# Progress Report

## Current Status
Phase 2 of 7: GitHub Actions release workflow
Status: COMPLETED

## What Was Done This Session
- .github/workflows/release.yml: Created release workflow triggered on v* tags; builds all 4 platform TUI binaries and uploads them as GitHub Release assets

## Immediate Next Task
Begin Phase 3: Replace install.sh with a standalone curl-piped installer that downloads jq and TUI binaries from GitHub Releases, extracts a tarball, and symlinks tarvos to /usr/local/bin.

## Key Files for Next Task
- install.sh (rewrite existing file)

## Gotchas
- install.sh must be self-contained (no dependency on local git clone)
- tarvos.sh depends on lib/ — release must ship a tarball; installer extracts it
- macOS: run xattr -dr com.apple.quarantine on downloaded binaries (Gatekeeper)
