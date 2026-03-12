# Tarvos — Developer Guide

## Prerequisites

| Tool | Purpose |
|------|---------|
| [`claude`](https://docs.anthropic.com/en/docs/claude-code) | Run agent sessions |
| [`bun`](https://bun.sh) | Build and develop the TUI |
| `bash` | Core runtime for `tarvos.sh` and `lib/` |
| `git` | Version control |

> `jq` is **not** required for contributors — it is bundled automatically by the installer. Bun is only needed when modifying or rebuilding the TUI.

---

## Getting the Code

```bash
git clone https://github.com/Photon48/tarvos.git
cd tarvos
```

---

## Production vs Development — the key distinction

There are two completely separate tarvos runtimes on your machine. They never interfere with each other.

| Command | Runs | Source |
|---------|------|--------|
| `tarvos` | production release | `~/.local/share/tarvos/tarvos.sh` |
| `tarvos-dev` | your local repo | `<your-repo>/tarvos.sh` |

**Production** (`tarvos`) is installed by the one-liner and lives entirely under `~/.local/share/tarvos/`. Editing your repo has zero effect on it. Run `tarvos update` to pull a new release.

**Development** (`tarvos-dev`) is a thin wrapper in the repo that always runs whatever branch is currently checked out. No install step, no env vars needed.

```bash
# production — stable release
tarvos init my-plan.md --name my-feature

# development — your local branch
tarvos-dev init my-plan.md --name my-feature
```

Every `tarvos-dev` invocation prints a banner to stderr so it is always obvious which runtime and branch is active:

```
[tarvos-dev] repo: /your/path/to/tarvos
[tarvos-dev] branch: my-feature-branch
[tarvos-dev] TUI: local build (darwin-arm64)
```

### Putting tarvos-dev on PATH

```bash
mkdir -p ~/bin
ln -sf "$PWD/tarvos-dev.sh" ~/bin/tarvos-dev
```

Add `~/bin` to your PATH in `~/.bashrc` (bash) or `~/.zshrc` (zsh):

```bash
export PATH="$HOME/bin:$PATH"
```

Then reload: `source ~/.bashrc` or `source ~/.zshrc`.

> **macOS bash note:** Interactive bash sessions on macOS load `~/.bash_profile` instead of `~/.bashrc`. Make sure your `.bash_profile` sources `.bashrc`, or add the export there directly.

---

## Project Layout

```
tarvos.sh              # main CLI entry point
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

## Working on tarvos.sh / lib/

The shell scripts run directly — no compilation step. Edit and test immediately:

```bash
# edit tarvos.sh or lib/*.sh, then test instantly from any project:
tarvos-dev init my-plan.md --name test

# switch branches and test without reinstalling:
git checkout my-experimental-branch
tarvos-dev begin test
```

The production `tarvos` command is never affected. Both can run simultaneously.

---

## Working on the TUI

The TUI uses [`@opentui/core`](https://github.com/anomalyco/opentui) with a React reconciler. It **must** be compiled with `bun build --compile` — it cannot run under Node.js because it uses `bun:ffi` for native rendering.

### First-time setup

```bash
cd tui && bun install
```

### Build for your platform (one-off)

```bash
cd tui
bun run build:darwin-arm64   # macOS Apple Silicon
bun run build:darwin-x64     # macOS Intel
bun run build:linux-x64      # Linux x86_64
bun run build:linux-arm64    # Linux ARM64
```

Output lands in `tui/dist/`.

### Iterating — auto-rebuild on every save

Run the watch script in a dedicated terminal. It rebuilds the binary automatically whenever any source file changes:

```bash
cd tui && bun run watch
```

### How tarvos-dev uses the local build

`tarvos-dev` **requires** a local TUI build in `tui/dist/` for your platform. It never falls back to the production binary — they are completely separate. If no local build exists, you get a clear error:

```
[tarvos-dev] ERROR: no local TUI binary found for darwin-arm64
[tarvos-dev] Build it first:
  cd .../tarvos/tui && bun run build:darwin-arm64
  # or to auto-rebuild on every save:
  cd .../tarvos/tui && bun run watch
```

Once built, `tarvos-dev tui` picks it up automatically — no env vars required.

### Typical TUI dev workflow

```bash
# terminal 1 — leave running while you work
cd tui && bun run watch

# terminal 2 — test from any project
tarvos-dev tui
```

To force a specific binary, `TUI_BIN_PATH` still works as an explicit override:

```bash
TUI_BIN_PATH="$(pwd)/tui/dist/tui-darwin-arm64" tarvos-dev tui
```

---

## Running Tests

```bash
bash tests/smoke-test.sh
```

Exercises `init`, `begin`, `stop`, `continue`, `accept`, `reject`, and `forget` against a temporary isolated git repo. All 19 tests must pass. `claude` is mocked — no real API calls are made.

---

## Making a Release

### 1. Verify everything works

```bash
bash tests/smoke-test.sh
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

### 3. Update the pinned version in install.sh

```bash
# in install.sh, update:
TARVOS_VERSION="v0.2.0"
```

Commit and push:

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
3. Run `bash tests/smoke-test.sh` — all 19 tests must pass
4. If you changed the TUI, build it and verify: `cd tui && bun run build:darwin-arm64 && tarvos-dev tui`
5. Open a PR against `main` — CI runs smoke tests automatically

---

## Environment Variables (dev overrides)

| Variable | Effect |
|----------|--------|
| `TUI_BIN_PATH` | Use this TUI binary instead of the auto-detected one |
| `TARVOS_JQ_PATH` | Use this jq binary instead of the bundled one |
| `TARVOS_DATA_DIR` | Override the data directory (default: `~/.local/share/tarvos`) |
