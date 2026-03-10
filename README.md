# Tarvos

> Keep your AI coding agent in the green.

LLMs don't process context uniformly. Performance degrades significantly as input length grows — every major model eventually falls toward random-chance quality as the context fills up. For agentic coding tasks, your agent is quietly getting dumber with every turn.

[![Model performance vs input length](./hero_plot.png)](https://research.trychroma.com/context-rot)

**Tarvos** orchestrates a chain of fresh agents, each picking up exactly where the last one left off — keeping every agent under 100k tokens where reasoning quality is highest.

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
tarvos init path/to/your-plan.md   # preview the plan, write .tarvos/config
tarvos begin                        # enter TUI and run the agent loop
tarvos begin --continue             # resume from existing progress.md
```

---

## How it works

Write a planning document describing what you want to build — phases, sprints, milestones, a task list, whatever structure makes sense for your project. See [`example.prd.md`](./example.prd.md) for an example.

**`tarvos init <plan>`** reads the document with a non-agentic Claude call, identifies the work units, and flags any obvious problems before you commit to a run. It writes a `.tarvos/config` file in your repo so `begin` knows what to do.

**`tarvos begin`** enters a full-screen TUI and starts the agent loop. Each iteration launches a fresh Claude Code agent against your plan. When an agent finishes a phase (or hits the token limit), it writes a `progress.md` handoff report and signals Tarvos. A new agent picks up from there.

The loop runs until the agent signals `ALL_PHASES_COMPLETE`, max loops is reached, or you press `Ctrl+C`.

---

## Commands

### `tarvos init <path-to-plan> [options]`

Validates and previews the plan, then writes `.tarvos/config`.

| Option | Default | Description |
|---|---|---|
| `--token-limit N` | `100000` | Token threshold that triggers a handoff to a fresh agent |
| `--max-loops N` | `50` | Maximum agent iterations before stopping |
| `--no-preview` | — | Skip the AI preview; parse headings locally and write config immediately |

The preview uses a single non-agentic LLM call (no tool loop) to read your plan regardless of structure and report:
- **VALID** — coherent plan, ready to go
- **WARN** — usable but something worth knowing (e.g. vague scope, no acceptance criteria)
- **INVALID** — not a workable plan; config is still written so you can proceed if you want

### `tarvos begin [--continue]`

Reads `.tarvos/config` and starts the agent loop. Errors clearly if `init` hasn't been run.

`--continue` resumes from an existing `progress.md` instead of starting fresh.

---

## State and logs

- **`.tarvos/config`** — written by `init`, read by `begin`. Add `.tarvos/` to your `.gitignore`.
- **`progress.md`** — the handoff report each agent writes before signalling completion. Lives in your project root. Safe to delete between runs (or let `begin` clear it automatically).
- **`logs/tarvos/run-<timestamp>/`** — per-loop raw JSONL, token usage snapshots, stderr, and a dashboard summary.

---

Work in progress. Contributions welcome.
