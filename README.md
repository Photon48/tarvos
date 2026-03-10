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
tarvos init path/to/your-plan.md --name my-feature
tarvos begin my-feature
```

---

## How it works

Write a planning document describing what you want to build — phases, sprints, milestones, a task list, whatever structure makes sense for your project. See [`example.prd.md`](./example.prd.md) for an example.

**`tarvos init <plan> --name <name>`** reads your document, previews it, and creates a named session.

**`tarvos begin <name>`** enters a full-screen TUI and starts the agent loop. Each iteration launches a fresh Claude Code agent against your plan. When an agent finishes a phase, a new agent picks up from there.

The loop runs until all phases are complete, max loops is reached, or you press `Ctrl+C`.

---

## Commands

### `tarvos init <path-to-plan> --name <name> [options]`

Previews the plan and creates a named session under `.tarvos/sessions/<name>/`.

| Option | Default | Description |
|---|---|---|
| `--name <name>` | required | A unique name for this session (alphanumeric + hyphens) |
| `--token-limit N` | `100000` | Token threshold that triggers a handoff to a fresh agent |
| `--max-loops N` | `50` | Maximum agent iterations before stopping |
| `--no-preview` | — | Skip the AI preview and create the session immediately |

### `tarvos begin <name> [--continue]`

Starts the agent loop for the named session.

`--continue` resumes from an existing progress checkpoint instead of starting fresh.

---

## State and logs

- **`.tarvos/sessions/<name>/`** — all state for a session lives here. Add `.tarvos/` to your `.gitignore`.
- **`progress.md`** — written per-session to track where the current run is up to.
- **Logs** — stored per-session under `.tarvos/sessions/<name>/logs/`.

---

Work in progress. Contributions welcome.
