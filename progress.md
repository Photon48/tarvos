# Progress Report

## Current Status
Phase 4 of 5: Worktree Isolation + Completion Summary
Status: COMPLETED

## What Was Done This Session
- lib/worktree-manager.sh: New file — worktree_create, worktree_remove, worktree_path, worktree_exists
- lib/branch-manager.sh: branch_create() now uses `git branch` (no checkout); worktree_create does the actual `git worktree add`
- lib/session-manager.sh: Added worktree_path field to state.json template, session_load, and session_set_worktree_path helper
- lib/summary-generator.sh: New file — generate_summary() calls claude non-agentically to produce ≤30-line summary, streams to summary.md and appends to dashboard.log
- lib/log-manager.sh: Added tui_show_completion_overlay() (full-screen panel with live summary streaming, [Enter]/[q] to dismiss, [s] to open in pager); log_final_summary() now accepts session_name arg and shows overlay on ALL_PHASES_COMPLETE
- tarvos.sh cmd_begin: Sources worktree-manager.sh; fresh sessions call worktree_create after branch_create; resumed sessions reuse or recreate the worktree; PROJECT_DIR is set to the worktree path
- tarvos.sh cmd_accept: Sources worktree-manager.sh; calls worktree_remove before branch_merge
- tarvos.sh cmd_reject: Sources worktree-manager.sh; calls worktree_remove before branch_delete (simplified — no need to checkout away since main tree is unaffected)
- tarvos.sh run_agent_loop: Sources summary-generator.sh; calls generate_summary on ALL_PHASES_COMPLETE; passes session_name to log_final_summary

## Immediate Next Task
Begin Phase 5: Create lib/tui-app.sh (single-process screen stack: list → run view → summary overlay), update tarvos.sh cmd_list and no-arg case to call tui_app_run, then create tests/smoke-test.sh with all 13 tests.

## Key Files for Next Task
- lib/tui-app.sh (new)
- tests/smoke-test.sh (new)
- tarvos.sh (cmd_list, main no-arg case)

## Gotchas
- cmd_reject no longer needs to `git checkout` away from the session branch first (main tree stays on its own branch; the session was running in a worktree)
- worktree paths are absolute (worktree_create returns absolute path); SESSION_WORKTREE_PATH stores the absolute path
