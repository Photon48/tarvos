# Tarvos

> Keep your AI coding agent in the green.

LLMs don't process context uniformly. Performance degrades significantly as input length grows — every major model eventually falls toward random-chance quality as the context fills up. For agentic coding tasks, your agent is quietly getting dumber with every turn.

[![Model performance vs input length](./hero_plot.png)](https://research.trychroma.com/context-rot)

**Tarvos** orchestrates a chain of fresh agents, each picking up exactly where the last one left off — keeping every agent under 100k tokens where reasoning quality is highest.

Run multiple plans concurrently. Each session gets its own git branch. Accept good work, reject bad experiments — without ever touching git yourself.

---

## Quickstart

**Prerequisites:** [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `jq`, `bash`

```bash
git clone https://github.com/your-org/tarvos.git
cd tarvos
./install.sh          # symlinks tarvos → /usr/local/bin/tarvos
```

Then from your project repo:

```bash
tarvos init path/to/your-plan.md --name my-feature
tarvos begin my-feature
```

---

## How it works

Write a planning document describing what you want to build — phases, sprints, milestones, a task list, whatever structure makes sense. See [`example.prd.md`](./example.prd.md) for an example.

1. **`tarvos init`** reads your plan and creates a named session.
2. **`tarvos begin`** creates a git branch for the session, opens a full-screen TUI, and starts the agent loop. Each iteration launches a fresh Claude Code agent. When an agent finishes a phase, a new agent picks up from there.
3. When the work is done, **`tarvos accept`** merges the branch back and archives the session. If you don't like the result, **`tarvos reject`** deletes it cleanly.

---

## Commands

### `tarvos init <path-to-plan> --name <name> [options]`

Previews the plan and creates a named session under `.tarvos/sessions/<name>/`.

| Option | Default | Description |
|---|---|---|
| `--name <name>` | required | Unique session name (alphanumeric + hyphens) |
| `--token-limit N` | `100000` | Token threshold that triggers a handoff to a fresh agent |
| `--max-loops N` | `50` | Maximum agent iterations before stopping |
| `--no-preview` | — | Skip the AI preview and create the session immediately |

---

### `tarvos begin <name> [options]`

Starts the agent loop for the named session. Creates a `tarvos/<name>-<timestamp>` git branch and checks it out. Requires a clean working directory.

| Option | Description |
|---|---|
| `--continue` | Resume from an existing progress checkpoint instead of starting fresh |
| `--bg` | Run in the background (detached). Use `tarvos attach` to follow output |

---

### `tarvos list`

Opens an interactive TUI showing all sessions and their status.

```
  TARVOS SESSIONS
  ─────────────────────────────────────────────────────────────
  Name              Status      Branch                     Activity
  ─────────────────────────────────────────────────────────────
▶ my-feature        running     tarvos/my-feature-0310     2m ago
  bugfix-login      done        tarvos/bugfix-login-0309   1h ago
  experiment        stopped     tarvos/experiment-0308     3d ago
  ─────────────────────────────────────────────────────────────
  [Enter] Actions  [q] Quit
```

Navigate with arrow keys, press `Enter` to open the actions menu for the selected session. Actions are context-aware based on session status.

---

### `tarvos attach <name>`

Tail live output of a background session. Press `Ctrl+C` to detach — the session keeps running.

---

### `tarvos stop <name>`

Stop a running background session (SIGTERM, then SIGKILL after 2 seconds).

---

### `tarvos accept <name>`

Merge a completed session's branch into your original branch, archive the session folder, and delete the session branch. Session must have status `done`.

```bash
tarvos accept my-feature
```

---

### `tarvos reject <name> [--force]`

Delete a session's branch and remove all session data. Use `--force` to skip the confirmation prompt. Session must not be currently running.

```bash
tarvos reject experiment
tarvos reject experiment --force
```

---

### `tarvos migrate`

Migrate a legacy Tarvos config (`.tarvos/config`) to the current session-based format. Creates a session named `default`, moves any existing `progress.md` into the session folder, and archives the old config as `.tarvos/config.bak`.

```bash
tarvos migrate
tarvos begin default
```

---

## State and logs

- **`.tarvos/sessions/<name>/`** — all state for a session lives here. Add `.tarvos/` to your `.gitignore`.
- **`state.json`** — session metadata: status, branch, token limit, loop count, timestamps.
- **`progress.md`** — written by each agent to hand off context to the next one.
- **`output.log`** — stdout/stderr for background sessions.
- **`logs/`** — per-run logs with raw stream JSON and token usage.

---

## Session lifecycle

```
init → begin → [running] → done → accept (merged + archived)
                                ↘ reject (deleted)
              → stopped → begin (resume)
                        ↘ reject (deleted)
```

---

Work in progress. Contributions welcome.
