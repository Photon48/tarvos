# Tarvos

> Run your AI coding plan to completion.

AI coding agents slow down as they go. The more context they accumulate, the worse their output gets — a well-known effect across every major model.

**Tarvos** solves this by running a chain of fresh agents on your plan, each one picking up exactly where the last left off. You write the plan once. Tarvos handles the rest.

Run multiple plans at once. Each session gets its own isolated git worktree. When the work is done, accept it to merge, or reject it to discard — without ever touching git yourself.

[![Model performance vs input length](./hero_plot.png)](https://research.trychroma.com/context-rot)

---

## Quickstart

**Prerequisites:** [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `jq`, `bash`, [`bun`](https://bun.sh)

```bash
git clone https://github.com/anomalyco/tarvos.git
cd tarvos
./install.sh          # adds 'tarvos' to /usr/local/bin
cd tui && bun install # install the session browser UI
```

Then from your project:

```bash
tarvos init my-plan.md --name my-feature
tarvos begin my-feature
tarvos tui             # watch it work
```

---

## How it works

1. **Write a plan.** Describe what you want to build — phases, tasks, milestones. Any format works. See [`example.prd.md`](./example.prd.md) for inspiration.

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
