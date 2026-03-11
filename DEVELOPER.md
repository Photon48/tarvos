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

---

## Production vs Development — the key distinction

There are two completely separate tarvos runtimes on your machine. They never interfere with each other.

| Command | Which tarvos runs | How to upgrade |
|---------|------------------|----------------|
| `tarvos` | `~/.local/share/tarvos/tarvos.sh` (the installed release) | `tarvos update` |
| `./tarvos-dev.sh` | `<your-repo>/tarvos.sh` (your local git branch) | `git checkout <branch>` |

**Production** (`tarvos`) is installed by the one-liner and lives entirely under `~/.local/share/tarvos/`. It is never touched by edits to your repo. Run `tarvos update` to pull a new release.

**Development** (`./tarvos-dev.sh`) is a thin wrapper checked into the repo. It always runs the `tarvos.sh` in the repo root — whatever branch you are currently on. No install step, no env vars, immediate feedback.

```bash
# production (stable, downloaded release)
tarvos init my-plan.md --name my-feature

# development (your local branch, whatever state it's in)
./tarvos-dev.sh init my-plan.md --name my-feature
```

Each invocation prints a small banner to stderr so it is always obvious which runtime you are using:

```
[tarvos-dev] repo: /Users/you/Documents/tarvos
[tarvos-dev] branch: my-experimental-branch
```

### Putting tarvos-dev on PATH (optional)

If you want to type `tarvos-dev` instead of `./tarvos-dev.sh` from any directory:

```bash
ln -sf "$PWD/tarvos-dev.sh" ~/bin/tarvos-dev
# ensure ~/bin is on PATH (add to ~/.zshrc if needed):
# export PATH="$HOME/bin:$PATH"
```

The symlink is to the absolute path of the script, so it continues to point at your repo regardless of where you call it from.

### Shared bundled dependencies

Both runtimes share the same bundled `jq` and TUI binaries at `~/.local/share/tarvos/bin/`. This is intentional — you only need one copy of the native binaries. If you are actively developing the TUI itself, see the TUI section below for how to override the binary per-invocation.

---

### Production install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/anomalyco/tarvos/main/install.sh | bash
```

This downloads jq and the prebuilt TUI binary into `~/.local/share/tarvos/bin/`, extracts `tarvos.sh` + `lib/` there, and symlinks `tarvos` into `/usr/local/bin`.

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

Use `tarvos-dev.sh` with the `TUI_BIN_PATH` override:

```bash
TUI_BIN_PATH="$(pwd)/tui/dist/tui-darwin-arm64" ./tarvos-dev.sh tui
```

This keeps production's TUI untouched while you iterate on yours.

`tarvos.sh` resolves the TUI binary in this order:
1. `$TUI_BIN_PATH` env var (dev override)
2. `~/.local/share/tarvos/bin/tui` (installed release binary)
3. `tui/dist/tui-<os>-<arch>` relative to the script (automatic dev fallback if neither above exists)

---

## Working on `tarvos.sh` / `lib/`

The scripts run directly — no compilation needed. Edit and run immediately via `tarvos-dev.sh`:

```bash
# edit tarvos.sh or lib/*.sh, then test instantly:
./tarvos-dev.sh <subcommand>

# switch to a different branch and test it without any reinstall:
git checkout my-experimental-branch
./tarvos-dev.sh begin my-session
```

The production `tarvos` command is never affected. Both can run simultaneously against different sessions.

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
