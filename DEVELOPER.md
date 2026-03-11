# Tarvos — Developer Guide

## Prerequisites

| Tool | Purpose |
|------|---------|
| [`claude`](https://docs.anthropic.com/en/docs/claude-code) | Run agent sessions |
| [`bun`](https://bun.sh) | Build and develop the TUI |
| `bash` | Core runtime for `tarvos.sh` and `lib/` |
| `git` | Version control |

> `jq` and `bun` are **not** required for end-users — they are bundled automatically by the installer. Bun is only needed when you want to modify or rebuild the TUI.

---

## Getting the Code

```bash
git clone https://github.com/anomalyco/tarvos.git
cd tarvos
```

### Install your local copy

```bash
./install.sh
```

This downloads bundled jq and the prebuilt TUI binary into `~/.local/share/tarvos/bin/`, extracts `tarvos.sh` + `lib/` there, and symlinks `tarvos` into `/usr/local/bin`.

---

## Project Layout

```
tarvos.sh          # main CLI entry point
lib/
  session-manager.sh   # session state, git worktrees
  context-monitor.sh   # token counting, phase handoffs
tui/
  src/index.tsx        # TUI source (React + OpenTUI)
  package.json         # build scripts
  dist/                # compiled binaries (gitignored)
install.sh             # standalone curl installer
tests/
  smoke-test.sh        # integration smoke tests
tarvos-skill/
  SKILL.md             # Claude skill injected into agent sessions
```

---

## Working on the TUI

The TUI uses [`@opentui/core`](https://github.com/anomalyco/opentui) with a React reconciler. It **must** be compiled with `bun build --compile` — it cannot run under Node.js because it uses `bun:ffi` for native rendering.

### Install dependencies

```bash
cd tui && bun install
```

### Run in dev mode (without compiling)

```bash
cd tui && bun run dev
# or
cd tui && bun run start
```

### Build a binary for your platform

```bash
cd tui
bun run build:darwin-arm64   # macOS Apple Silicon
bun run build:darwin-x64     # macOS Intel
bun run build:linux-x64      # Linux x86_64
bun run build:linux-arm64    # Linux ARM64
bun run build:all             # all platforms
```

Output lands in `tui/dist/`.

### Test your local TUI build without reinstalling

```bash
TUI_BIN_PATH="$(pwd)/tui/dist/tui-darwin-arm64" tarvos tui
```

`tarvos.sh` resolves the TUI binary in this order:
1. `$TUI_BIN_PATH` env var
2. `~/.local/share/tarvos/bin/tui` (installed)
3. `tui/dist/tui-<os>-<arch>` relative to the script (dev fallback)

---

## Working on `tarvos.sh` / `lib/`

The scripts run directly — no compilation needed. Edit and run immediately:

```bash
# after editing tarvos.sh or lib/*.sh
tarvos <subcommand>
```

If you installed via `install.sh`, your system `tarvos` points to the copy in `~/.local/share/tarvos/tarvos.sh`. To test local edits without reinstalling, either:

- Re-run `./install.sh` (fast, reruns extract step)
- Or invoke the script directly: `bash tarvos.sh <subcommand>`

---

## Running Tests

```bash
bash tests/smoke-test.sh
```

The smoke tests exercise `init`, `begin`, `stop`, `continue`, `accept`, `reject`, and `forget` against a temporary git repo. All 19 tests should pass. Tests mock `claude` so no real API calls are made.

---

## Making a Release

### 1. Verify everything works

```bash
bash tests/smoke-test.sh   # all 19 tests pass
```

### 2. Tag the release

```bash
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions (`.github/workflows/release.yml`) triggers on the tag and:

- Installs TUI dependencies (`bun install`)
- Compiles all four platform binaries (`bun run build:all`)
- Packages `tarvos.sh`, `lib/`, and `tarvos-skill/` into `tarvos-v0.2.0.tar.gz`
- Creates a GitHub Release and uploads all assets

### 3. Update the pinned version in `install.sh`

```bash
# in install.sh, update:
TARVOS_VERSION="v0.2.0"
```

Commit and push to `main`:

```bash
git add install.sh
git commit -m "chore: bump TARVOS_VERSION to v0.2.0"
git push origin main
```

Users can now run `tarvos update` or re-run the one-liner to get the new version.

---

## Opening a Pull Request

1. Fork or branch from `main`
2. Make your changes
3. Run `bash tests/smoke-test.sh` — all tests must pass
4. If you changed the TUI, build it locally and verify: `TUI_BIN_PATH=tui/dist/tui-darwin-arm64 tarvos tui`
5. Open a PR against `main` — CI will run smoke tests automatically
6. Once merged, follow the release steps above to cut a new version

---

## Environment Variables (dev overrides)

| Variable | Effect |
|----------|--------|
| `TUI_BIN_PATH` | Use this TUI binary instead of the installed one |
| `TARVOS_JQ_PATH` | Use this jq binary instead of the bundled one |
| `TARVOS_DATA_DIR` | Override the data directory (default: `~/.local/share/tarvos`) |
