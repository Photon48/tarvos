# Tarvos

[![CI](https://github.com/Photon48/tarvos/actions/workflows/ci.yml/badge.svg)](https://github.com/Photon48/tarvos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> No More Context Rot.

LLMs degrade as context fills up. You've felt it — the agent starts strong on Phase 1, then gets fuzzy by Phase 4. Your AI is spending half its context window just remembering what it already did. So you manually copy the PRD into a fresh session and pick up where it left off. That's not an autonomous developer. That's babysitting.

**Tarvos** fixes it. It automatically spawns fresh agents from a progress handoff whenever context crosses 50%, keeping every phase at full quality. You write the plan once. Tarvos runs it to completion, unattended.

Run multiple plans at once. Each session gets its own isolated git worktree. When the work is done, accept it to merge, or reject it to discard — without ever touching git yourself.

[![Model performance vs input length](./hero_plot.png)](https://research.trychroma.com/context-rot)

---

## Quickstart

**Prerequisites:** [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI

```bash
curl -fsSL https://raw.githubusercontent.com/Photon48/tarvos/main/install.sh | bash
```

Then from your project:

```bash
tarvos init my-plan.md --name my-feature
tarvos begin my-feature
tarvos tui
```

---

## Example: Building a feature end-to-end

Use your AI coding tool's plan mode to design what you want to build. Once you're happy with the plan, ask it to save the file into your project:

> "Plan out a payments integration. Save it to `prds/payments-v1.md`."

Then hand it to Tarvos:

```bash
tarvos init prds/payments-v1.md --name payments
tarvos begin payments
tarvos tui
```

Tarvos creates an isolated git branch, runs fresh agents phase by phase, and writes a progress handoff between each one. When it's done, accept or reject from the TUI — no git required.

> **Tip:** Keep older PRDs in `prds/archive/` as a record of past work and past decisions.

---

## How it works

1. **Write a plan.** Use your AI coding tool's plan mode to describe what you want to build — phases, tasks, milestones. Ask it to save the plan into your project (e.g. `prds/my-feature.md`). Keep older plans in `prds/archive/` for reference. See [`example.prd.md`](./example.prd.md) for format inspiration.

2. **`tarvos init`** reads your plan, previews it, and creates a session — a named workspace with its own git branch and isolated working directory.

3. **`tarvos begin`** starts the agent in the background. It works through your plan one phase at a time, each fresh agent picking up from a handoff note left by the previous one.

4. **`tarvos tui`** opens the session browser where you can watch progress, view the activity log, and take action when work is done.

5. When done, **`tarvos accept`** merges the changes into your branch and cleans up. **`tarvos reject`** discards everything cleanly if you don't like the result. **`tarvos forget`** removes the session from Tarvos while leaving the git branch untouched for you to handle manually.

---

## Commands

### `tarvos` / `tarvos tui`

Open the session browser. Run `tarvos` with no arguments or `tarvos tui`.

```
╭── Sessions ──────────────────────────────── 3 sessions ───╮
│                                                            │
│ ▶  ⠋ my-feature     running      tarvos/my-feature-…  2m ago │
│    ✓ bugfix-login   done         tarvos/bugfix-login-… 1h ago │
│    ○ experiment     initialized  —                     —      │
│                                                            │
╰────────────────────────────────────────────────────────────╯
[↑↓] Navigate  [Enter] Open/Actions  [n] New  [q] Quit
```

Keys: `↑`/`k` up, `↓`/`j` down, `Enter` open or actions menu, `n` new session, `R` refresh, `q` quit.

Actions menu (context-aware per session status):
- **running** → View, Stop
- **stopped** → Continue, Reject
- **done** → Accept, Reject, Forget, View Summary
- **initialized** → Start, Reject
- **failed** → Reject, Forget

Use `tarvos tui view <session>` to open the run dashboard for a specific session directly.

---

### `tarvos init <plan.md> --name <name> [options]`

Read a plan file and create a named session.

| Option | Default | Description |
|---|---|---|
| `--name <name>` | required | Session name (alphanumeric + hyphens) |
| `--token-limit N` | `100000` | How much context an agent uses before handing off |
| `--max-loops N` | `50` | Maximum number of agent iterations |
| `--no-preview` | — | Skip the plan preview and create the session immediately |

---

### `tarvos begin <name>`

Start the agent loop for a session. Always runs in the background — use `tarvos tui` to monitor progress.

---

### `tarvos continue <name>`

Resume a stopped session from where it left off. No progress is lost.

---

### `tarvos accept <name>`

Merge a completed session's changes into your original branch and clean up. Session must have status `done`.

The accepted session is archived to `.tarvos/archive/` — its metadata and logs are preserved there even after the branch is merged.

If another plan was accepted first and modified the same files, Tarvos will detect the conflict and exit cleanly **before** attempting any merge. Your working tree is untouched. Follow the printed instructions to resolve the conflict manually.

---

### `tarvos reject <name> [--force]`

Discard a session — deletes the branch and all its data. Use `--force` to skip the confirmation prompt. When prompted, you must type the full word `yes` to confirm. Session must not be running.

---

### `tarvos stop <name>`

Stop a running session. Resume it later with `tarvos continue`.

---

### `tarvos forget <name> [--force]`

Remove a session from Tarvos without deleting its git branch. Use `--force` to skip the confirmation prompt.

The session's worktree is removed (if present) and its Tarvos metadata is archived. The git branch is left exactly as-is — you can check it out, merge it manually, open a PR, or delete it yourself.

Use this when you want to handle the branch outside of Tarvos: cherry-pick changes, resolve conflicts yourself, or merge via a pull request.

> **Note:** Tarvos will no longer track this session after `forget`. The branch is yours to handle. You can find the archived session metadata in `.tarvos/archive/`.

Session must have status `done` or `failed`. Use `tarvos stop` first if the session is still running.

---

### `tarvos update [--version v0.x.y] [--force]`

Download and install the latest Tarvos release (or a specific version). Replaces the TUI binary and `tarvos.sh` in place. Skips re-downloading jq unless `--force` is passed.

```bash
tarvos update               # latest release
tarvos update --version v0.2.0
```

---

### `tarvos migrate`

Upgrade a project from an older Tarvos configuration format. If you have a legacy `.tarvos/config` file from a previous Tarvos version, this command converts it to the current session format.

```bash
tarvos migrate
```

---

## Session lifecycle

```
init → begin → [running] → done ──→ accept  (changes merged, session archived)
                         │        ↘ reject  (changes discarded)
                         │        ↘ forget  (branch kept, session archived)
                         ↓
                       failed ──→ reject  (discard branch)
                               ↘ forget  (keep branch)
                         ↓
                       stopped → continue (resume)
                               ↘ reject  (discard)
```

After a session reaches `done`, a summary is automatically generated and saved to `.tarvos/sessions/<name>/summary.md`. In the TUI run dashboard, the footer will briefly show "Generating summary…" and then update to `[s] View Summary` once it's ready. You can also access it from the session list actions overlay → "View Summary".

---

## Where things live

Everything is under `.tarvos/` in your project (automatically gitignored):

- **`sessions/<name>/`** — session state, progress handoff notes, summary, logs
- **`worktrees/<name>/`** — the isolated working directory for each session (removed on accept/reject/forget)
- **`archive/<name>-<ts>/`** — archived session metadata after accept, reject, or forget

---

## Development

To work on Tarvos itself you need [`bun`](https://bun.sh) to rebuild the TUI binary.

### Rebuild the TUI

```bash
cd tui && bun install
bun run build:darwin-arm64   # or build:darwin-x64, build:linux-x64, build:linux-arm64, build:all
```

Test your local build without reinstalling:

```bash
TUI_BIN_PATH="$(pwd)/tui/dist/tui-darwin-arm64" tarvos tui
```

### Release process

1. Tag a new version: `git tag v0.2.0 && git push --tags`
2. GitHub Actions builds all platform binaries and creates the release
3. Update `TARVOS_VERSION` in `install.sh` and commit
