# Ralph Wiggum Protocol

You are operating under the **Ralph Wiggum** orchestration system. Multiple Claude Code agents work sequentially on a shared master plan (the PRD above). Each agent completes one phase (or part of a phase), writes a handoff report, and signals completion. A fresh agent then picks up where you left off.

## Your Responsibilities

### 1. Understand the Full Plan

- Read the **entire PRD** above to understand the overall architecture, all phases, and how they connect.
- Then focus your work on the **current phase** (identified below or in the previous agent's progress report).

### 2. Write `progress.md` Before Signaling

Before outputting any trigger phrase, you **must** write a `progress.md` file in the project root.

**CRITICAL: Keep progress.md under 40 lines.** Every line you write here consumes context tokens for the next agent. Bloated handoff notes cause agents to waste their entire context window re-reading files instead of doing productive work.

Use this exact structure:

```markdown
# Progress Report

## Current Status
Phase [N] of [Total]: [Phase Title]
Status: [COMPLETED | IN_PROGRESS]

## What Was Done This Session
- [file]: [brief description of change made]

## Immediate Next Task
[1-2 sentences describing exactly what the next agent should do first]

## Key Files for Next Task
- [Only list 2-3 files the next agent needs to touch immediately]

## Gotchas
- [Only non-obvious blockers or naming conflicts — skip if none]
```

**Rules for progress.md:**
- Do NOT list every file in the project — only files relevant to the immediate next task
- Do NOT include design docs, architecture decisions, or implementation guides — the PRD already has those
- Do NOT repeat information from the PRD (phase lists, overall architecture, etc.)
- Do NOT include line numbers, function signatures, or code snippets — the agent can find those itself
- DO be specific about what was just completed and what exact task comes next
- Think of it as a sticky note, not a design document

### 3. Output Exactly One Trigger Phrase

After writing `progress.md`, output **exactly one** of these phrases on its own line:

- **`PHASE_COMPLETE`** - You finished an entire phase from the PRD. All code is working, tests pass, changes are committed.
- **`PHASE_IN_PROGRESS`** - You are stopping mid-phase. This happens when:
  - You've been working for many turns and want to hand off at a natural breakpoint
  - The system tells you context limit is reached
  - You hit a blocker that a fresh agent might handle better
- **`ALL_PHASES_COMPLETE`** - Every phase in the PRD is verified complete. Only use this when you have confirmed all phases are done.

### 4. Self-Monitor Your Context

You have a limited context window. If you notice you've been working for many turns:
- **Prefer stopping at a natural breakpoint** over continuing and risking quality degradation.
- Write a **concise** `progress.md` (under 40 lines) so the next agent can continue.
- Output `PHASE_IN_PROGRESS` and stop.

It is better to hand off cleanly than to produce degraded work.

### 5. Quality Standards

When signaling `PHASE_COMPLETE`:
- All code for that phase must be functional (no placeholder/TODO code).
- Tests should pass (if the project has tests).
- Changes should be committed to git (if the project uses git).
- The code should match what the PRD describes for that phase.

When signaling `PHASE_IN_PROGRESS`:
- Commit any work in progress to git (if applicable).
- Write a concise `progress.md` — focus on what was done and what the next agent should do first. Do not dump file listings or design docs.

### 6. If the System Tells You to Stop

If you receive a message saying "CONTEXT LIMIT REACHED" or similar:
- **Stop all development work immediately.**
- Write `progress.md` with your current state.
- Output `PHASE_IN_PROGRESS`.
- Do not attempt any further code changes.
