# Tarvos

> Keep your AI coding agent in the green.

---

If you've used Claude Code, Cursor, or any agentic coding tool for a large feature, you've hit the wall: the context window fills up, the agent starts losing the plot, and the quality of output quietly falls off a cliff. You either restart and lose continuity, or you push through and get mush.

**Tarvos** solves this by orchestrating a chain of fresh agents, each picking up exactly where the last one left off — keeping every agent well under 100k tokens where reasoning quality is highest.

---

## How it works

You write a PRD (a markdown file describing your project in phases). Tarvos does the rest.

Each agent:
1. Reads the PRD and the previous agent's handoff note
2. Does the work for the current phase
3. Writes a concise `progress.md` and signals completion
4. Hands off to a fresh agent that continues without context baggage

The orchestrator manages the loop, monitors token usage in real time, and handles edge cases like mid-phase context limits and failed handoffs — automatically.

---

## Quickstart

**Prerequisites:** [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `jq`, `bash`

```bash
# Clone the repo
git clone https://github.com/your-org/tarvos.git
cd tarvos

# Write a PRD (see example.prd.md for reference)
# Then run:
./ralph-wiggum.sh path/to/your.prd.md
```

That's it. Watch the TUI dashboard as agents work through your phases.

---

## PRD format

A PRD is just a markdown file with `## Phase N:` headings. See [`example.prd.md`](./example.prd.md) for a working example.

---

## Options

| Flag | Default | Description |
|---|---|---|
| `--token-limit N` | `100000` | Max tokens per agent before handoff |
| `--max-loops N` | `50` | Max agent iterations before stopping |
| `--continue` | — | Resume from an existing `progress.md` |

---

## Status

Work in progress. Core orchestration loop works. Rough edges remain.

Contributions welcome.
