# Tarvos

> Keep your AI coding agent in the green.

LLMs don't process context uniformly. Performance degrades significantly as input length grows — every major model eventually falls toward random-chance quality as the context fills up. For agentic coding tasks, your agent is quietly getting dumber with every turn.

![Model performance vs input length](./hero_plot.png)

**Tarvos** orchestrates a chain of fresh agents, each picking up exactly where the last one left off — keeping every agent under 100k tokens where reasoning quality is highest.

---

## Quickstart

**Prerequisites:** [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `jq`, `bash`

```bash
git clone https://github.com/your-org/tarvos.git
cd tarvos
./ralph-wiggum.sh path/to/your.prd.md
```

Write a PRD — a markdown file with `## Phase N:` headings describing your project. See [`example.prd.md`](./example.prd.md). Tarvos handles the rest.

**Options:** `--token-limit N` (default: 100k) · `--max-loops N` (default: 50) · `--continue` (resume from existing progress)

---

Work in progress. Contributions welcome.
