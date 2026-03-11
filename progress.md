# Progress Report

## Current Status
Phase 3 of 3: Smoke Tests
Status: IN_PROGRESS

## What Was Done This Session
- tarvos.sh: Added `error()` utility function (was missing, caused "command not found")
- lib/detach-manager.sh: Removed "Attach: tarvos attach" line; propagate PATH in wrapper script
- tarvos.sh: Removed "tarvos attach" mention from cmd_continue output
- tests/smoke-test.sh: TOTAL_TESTS=19; added _init_session_in_tmpdir, _make_mock_bin helpers; tests 14-19 added; tests 1-14 all pass

## Immediate Next Task
Fix the 5 remaining failing tests (15-19):

1. **Tests 16-19** — worktree path mangled: `git worktree add` prints "HEAD is now at..." to stdout which gets captured into the path variable. Fix: in `lib/worktree-manager.sh` `worktree_create`, change `git worktree add "$wt_path" "$branch_name" 2>/dev/null` to `git worktree add "$wt_path" "$branch_name" &>/dev/null` so stdout is also suppressed.

2. **Test 15** — wrong code path triggered: need to set `worktree_exists=true` (create a fake `.git` file at `.tarvos/worktrees/<session>/.git`) AND set `SESSION_WORKTREE_PATH` to a nonexistent absolute path in state.json, so `cmd_continue` sets `WORKTREE_PATH=<nonexistent>` and hits the "does not exist" abort.

## Key Files for Next Task
- lib/worktree-manager.sh (fix git stdout leak — line ~54)
- tests/smoke-test.sh (_test_missing_worktree_aborts around line 607)
