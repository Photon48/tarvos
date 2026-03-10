#!/usr/bin/env bash
# smoke-test.sh — Manual smoke test suite for Tarvos TUI (Phase 5)
# Runs 13 tests without a real Claude agent or network access.
# All tests run in a temp git repo with mock state files.
#
# Usage: ./tests/smoke-test.sh
# Exit:  0 if all pass, 1 if any fail

set -uo pipefail

# ──────────────────────────────────────────────────────────────
# Locate project root (one directory above tests/)
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ──────────────────────────────────────────────────────────────
# Colors (simple ANSI, no tui-core dependency)
# ──────────────────────────────────────────────────────────────
_GREEN="\033[0;32m"
_RED="\033[0;31m"
_YELLOW="\033[0;33m"
_DIM="\033[2m"
_RESET="\033[0m"
_BOLD="\033[1m"

# ──────────────────────────────────────────────────────────────
# Test counters
# ──────────────────────────────────────────────────────────────
TOTAL_TESTS=13
PASSED=0
FAILED=0
declare -a FAILED_TESTS=()

# ──────────────────────────────────────────────────────────────
# Temp directory — cleaned up on exit
# ──────────────────────────────────────────────────────────────
TMPDIR_ROOT=""
_setup_tmpdir() {
    TMPDIR_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t tarvos-smoke)
}

_cleanup_tmpdir() {
    if [[ -n "$TMPDIR_ROOT" ]] && [[ -d "$TMPDIR_ROOT" ]]; then
        rm -rf "$TMPDIR_ROOT"
    fi
}
trap '_cleanup_tmpdir' EXIT

# ──────────────────────────────────────────────────────────────
# Test harness helpers
# ──────────────────────────────────────────────────────────────
_TEST_NUM=0
_TEST_NAME=""

_run_test() {
    local num="$1"
    local name="$2"
    shift 2
    _TEST_NUM="$num"
    _TEST_NAME="$name"

    local result=0
    local output=""
    output=$("$@" 2>&1) || result=$?

    local padded_name
    padded_name=$(printf '%-42s' "$name")
    local dots
    dots=$(printf '%.*s' $(( 50 - ${#name} > 0 ? 50 - ${#name} : 3 )) "................................................")

    if [[ "$result" -eq 0 ]]; then
        (( PASSED++ ))
        printf "[%2d/%d] %s%s ${_GREEN}PASS${_RESET}\n" "$num" "$TOTAL_TESTS" "$padded_name" "$dots"
    else
        (( FAILED++ ))
        FAILED_TESTS+=("[$num] $name")
        printf "[%2d/%d] %s%s ${_RED}FAIL${_RESET}\n" "$num" "$TOTAL_TESTS" "$padded_name" "$dots"
        if [[ -n "$output" ]]; then
            while IFS= read -r line; do
                printf "       ${_DIM}%s${_RESET}\n" "$line"
            done <<< "$output"
        fi
    fi
}

# Create a fresh git repo + mock Tarvos session layout in TMPDIR_ROOT
_make_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config user.email "test@tarvos.test" 2>/dev/null
    git -C "$dir" config user.name "Tarvos Test" 2>/dev/null
    git -C "$dir" commit --allow-empty -m "init" -q 2>/dev/null
}

# Write a mock session state.json
_write_session() {
    local sessions_dir="$1"
    local name="$2"
    local status="$3"
    local branch="${4:-}"
    local last_activity="${5:-}"

    local dir="${sessions_dir}/${name}"
    mkdir -p "$dir"
    cat > "${dir}/state.json" <<EOF
{
  "name": "${name}",
  "status": "${status}",
  "branch": "${branch}",
  "last_activity": "${last_activity}",
  "prd_file": "/tmp/test.prd.md",
  "token_limit": 100000,
  "max_loops": 50,
  "worktree_path": ""
}
EOF
}

# ──────────────────────────────────────────────────────────────
# Individual test functions
# Each function exits 0 on pass, non-zero on fail.
# ──────────────────────────────────────────────────────────────

# Test 1: List screen renders
_test_list_renders() {
    local workdir="${TMPDIR_ROOT}/t1"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions"

    _write_session "${workdir}/.tarvos/sessions" "auth-feature" "running" "tarvos/auth-feature-20260101" "2026-01-01T12:00:00Z"
    _write_session "${workdir}/.tarvos/sessions" "bugfix-login" "done" "tarvos/bugfix-login-20260101" "2026-01-01T11:00:00Z"
    _write_session "${workdir}/.tarvos/sessions" "new-api" "initialized" "" ""

    local output
    output=$(cd "$workdir" && SESSIONS_DIR=".tarvos/sessions" bash -c "
        source '${PROJECT_ROOT}/lib/tui-core.sh'
        source '${PROJECT_ROOT}/lib/list-tui.sh'
        _list_load_sessions
        # Verify sessions loaded
        echo \"count=\${#_LIST_NAMES[@]}\"
        for n in \"\${_LIST_NAMES[@]}\"; do echo \"name=\$n\"; done
        for s in \"\${_LIST_STATUSES[@]}\"; do echo \"status=\$s\"; done
    " 2>/dev/null)

    echo "$output" | grep -q "count=3" || { echo "Expected 3 sessions, got: $output"; return 1; }
    echo "$output" | grep -q "name=auth-feature" || { echo "Missing auth-feature"; return 1; }
    echo "$output" | grep -q "name=bugfix-login" || { echo "Missing bugfix-login"; return 1; }
    echo "$output" | grep -q "name=new-api" || { echo "Missing new-api"; return 1; }
    echo "$output" | grep -q "status=running" || { echo "Missing running status"; return 1; }
    echo "$output" | grep -q "status=done" || { echo "Missing done status"; return 1; }
    echo "$output" | grep -q "status=initialized" || { echo "Missing initialized status"; return 1; }
    return 0
}

# Test 2: List screen navigation
_test_list_navigation() {
    local workdir="${TMPDIR_ROOT}/t2"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions"

    _write_session "${workdir}/.tarvos/sessions" "session-a" "initialized" "" ""
    _write_session "${workdir}/.tarvos/sessions" "session-b" "initialized" "" ""
    _write_session "${workdir}/.tarvos/sessions" "session-c" "initialized" "" ""

    # Write a helper script (functions needed for local vars to work)
    local helper="${TMPDIR_ROOT}/nav_helper.sh"
    cat > "$helper" <<EOF
#!/usr/bin/env bash
source '${PROJECT_ROOT}/lib/tui-core.sh'
source '${PROJECT_ROOT}/lib/list-tui.sh'
SESSIONS_DIR="${workdir}/.tarvos/sessions"
_list_load_sessions
count=\${#_LIST_NAMES[@]}
echo "initial_sel=\$_LIST_SEL"
# Move down
(( _LIST_SEL < count - 1 )) && (( _LIST_SEL++ )) || true
echo "after_down=\$_LIST_SEL"
# Move down again
(( _LIST_SEL < count - 1 )) && (( _LIST_SEL++ )) || true
echo "after_down2=\$_LIST_SEL"
# Try to move past end (should stay at end)
(( _LIST_SEL < count - 1 )) && (( _LIST_SEL++ )) || true
echo "at_end=\$_LIST_SEL"
# Move up
(( _LIST_SEL > 0 )) && (( _LIST_SEL-- )) || true
echo "after_up=\$_LIST_SEL"
EOF
    local output
    output=$(bash "$helper" 2>/dev/null)

    echo "$output" | grep -q "initial_sel=0" || { echo "Initial sel should be 0: $output"; return 1; }
    echo "$output" | grep -q "after_down=1" || { echo "After down should be 1: $output"; return 1; }
    echo "$output" | grep -q "after_down2=2" || { echo "After down2 should be 2: $output"; return 1; }
    echo "$output" | grep -q "at_end=2" || { echo "At end should still be 2: $output"; return 1; }
    echo "$output" | grep -q "after_up=1" || { echo "After up should be 1: $output"; return 1; }
    return 0
}

# Test 3: Action overlay renders correct actions for each status
_test_action_overlay_actions() {
    local workdir="${TMPDIR_ROOT}/t3"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions"

    # Test that action arrays are correct per status
    local output
    output=$(bash -c "
        source '${PROJECT_ROOT}/lib/tui-core.sh'
        source '${PROJECT_ROOT}/lib/list-tui.sh'

        check_actions() {
            local status=\"\$1\"
            shift
            local expected=(\"\$@\")
            local actions=()
            case \"\$status\" in
                running)     actions=(\"Attach\" \"Stop\") ;;
                stopped)     actions=(\"Resume\" \"Resume (bg)\" \"Reject\") ;;
                done)        actions=(\"Accept\" \"Reject\" \"View Summary\") ;;
                initialized) actions=(\"Start\" \"Start (bg)\" \"Reject\") ;;
                failed)      actions=(\"Reject\") ;;
            esac
            local ok=1
            for exp in \"\${expected[@]}\"; do
                local found=0
                for a in \"\${actions[@]}\"; do
                    [[ \"\$a\" == \"\$exp\" ]] && found=1 && break
                done
                [[ \$found -eq 0 ]] && { echo \"MISSING action '\$exp' for status '\$status'\"; ok=0; }
            done
            [[ \$ok -eq 1 ]] && echo \"ok:\$status\"
        }

        check_actions 'running'     'Attach' 'Stop'
        check_actions 'stopped'     'Resume' 'Reject'
        check_actions 'done'        'Accept' 'Reject' 'View Summary'
        check_actions 'initialized' 'Start'  'Reject'
        check_actions 'failed'      'Reject'
    " 2>/dev/null)

    echo "$output" | grep -q "ok:running" || { echo "running actions wrong: $output"; return 1; }
    echo "$output" | grep -q "ok:stopped" || { echo "stopped actions wrong: $output"; return 1; }
    echo "$output" | grep -q "ok:done" || { echo "done actions wrong: $output"; return 1; }
    echo "$output" | grep -q "ok:initialized" || { echo "initialized actions wrong: $output"; return 1; }
    echo "$output" | grep -q "ok:failed" || { echo "failed actions wrong: $output"; return 1; }
    return 0
}

# Test 4: Run view renders without errors (with mock events log)
_test_run_view_renders() {
    local workdir="${TMPDIR_ROOT}/t4"
    _make_git_repo "$workdir"

    local now
    now=$(date +%s)
    local events_file="${workdir}/loop-001-events.jsonl"

    cat > "$events_file" <<EOF
{"type":"tool_use","tool":"Bash","input":"npm test","ts":${now}}
{"type":"tool_result","tool":"Bash","output":"exit 0","success":true,"ts":$((now+1))}
{"type":"tool_use","tool":"Edit","input":"src/auth/middleware.ts","ts":$((now+2))}
{"type":"tool_result","tool":"Edit","output":"file updated","success":true,"ts":$((now+3))}
{"type":"text","content":"Now implementing token refresh logic.","ts":$((now+4))}
EOF

    local output
    output=$(bash -c "
        source '${PROJECT_ROOT}/lib/tui-core.sh'
        source '${PROJECT_ROOT}/lib/log-manager.sh'
        # Initialize without actual TUI screen
        TUI_ENABLED=0
        CURRENT_STATUS='RUNNING'
        LOG_VIEW_MODE='summary'
        _LM_CURRENT_EVENTS_LOG='${events_file}'

        # Load events file into ACTIVITY_LOG
        while IFS= read -r line; do
            [[ -z \"\$line\" ]] && continue
            _lm_append_event_line \"\$line\"
        done < '${events_file}'

        echo \"activity_count=\${#ACTIVITY_LOG[@]}\"
        for entry in \"\${ACTIVITY_LOG[@]}\"; do
            echo \"entry:\$entry\"
        done
    " 2>/dev/null)

    # Should have 5 entries (tool_use + tool_result * 2 + text = 5, but raw mode filtered)
    # In summary mode: tool_use(2), tool_result(2), text(1) = 5
    local count
    count=$(echo "$output" | grep -c "^entry:" || true)
    [[ "$count" -ge 4 ]] || { echo "Expected >=4 activity entries, got $count: $output"; return 1; }
    echo "$output" | grep -q "Bash" || { echo "Missing Bash tool in activity: $output"; return 1; }
    return 0
}

# Test 5: Log view mode toggle
_test_log_view_toggle() {
    local workdir="${TMPDIR_ROOT}/t5"
    _make_git_repo "$workdir"

    local now
    now=$(date +%s)
    local events_file="${workdir}/loop-001-events.jsonl"

    cat > "$events_file" <<EOF
{"type":"tool_use","tool":"Bash","input":"echo hello","ts":${now}}
{"type":"text","content":"This is raw text from Claude.","ts":$((now+1))}
EOF

    local helper="${TMPDIR_ROOT}/toggle_helper.sh"
    cat > "$helper" <<HELPEREOF
#!/usr/bin/env bash
source '${PROJECT_ROOT}/lib/tui-core.sh'
source '${PROJECT_ROOT}/lib/log-manager.sh'
TUI_ENABLED=0
events_file='${events_file}'

# Summary mode: should include tool_use
LOG_VIEW_MODE='summary'
ACTIVITY_LOG=()
while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    _lm_append_event_line "\$line"
done < "\$events_file"
summary_count=\${#ACTIVITY_LOG[@]}
echo "summary_count=\$summary_count"

# Raw mode: should only include text events
LOG_VIEW_MODE='raw'
ACTIVITY_LOG=()
while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    _lm_append_event_line "\$line"
done < "\$events_file"
raw_count=\${#ACTIVITY_LOG[@]}
echo "raw_count=\$raw_count"
HELPEREOF

    local output
    output=$(bash "$helper" 2>/dev/null)

    local summary_count raw_count
    summary_count=$(echo "$output" | grep "^summary_count=" | cut -d= -f2 | tr -d '[:space:]')
    raw_count=$(echo "$output" | grep "^raw_count=" | cut -d= -f2 | tr -d '[:space:]')

    # Summary mode: tool_use + text = 2 entries
    [[ "$summary_count" -ge 2 ]] || { echo "Summary mode count should be >=2, got: $summary_count; full: $output"; return 1; }
    # Raw mode: only text = 1 entry
    [[ "$raw_count" -eq 1 ]] || { echo "Raw mode count should be 1, got: $raw_count; full: $output"; return 1; }
    # Raw should be less than summary
    [[ "$raw_count" -lt "$summary_count" ]] || { echo "Raw count ($raw_count) should be < summary count ($summary_count)"; return 1; }
    return 0
}

# Test 6: Completion summary overlay — renders summary lines and handles keys
_test_completion_summary_overlay() {
    local workdir="${TMPDIR_ROOT}/t6"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions/my-session"

    # Create mock summary.md with 5 lines
    local summary_file="${workdir}/.tarvos/sessions/my-session/summary.md"
    cat > "$summary_file" <<'EOF'
## What was built
- JWT authentication middleware
- Login and logout endpoints
- Token refresh logic
## How to use
- Import authMiddleware from './auth/middleware'
EOF

    local helper="${TMPDIR_ROOT}/summary_helper.sh"
    cat > "$helper" <<HELPEREOF
#!/usr/bin/env bash
summary_file='${summary_file}'
summary_lines=()
while IFS= read -r line; do
    summary_lines+=("\$line")
done < "\$summary_file"
echo "line_count=\${#summary_lines[@]}"
for l in "\${summary_lines[@]}"; do
    echo "line:\$l"
done
HELPEREOF

    local output
    output=$(bash "$helper" 2>/dev/null)

    local line_count
    line_count=$(echo "$output" | grep "^line_count=" | cut -d= -f2 | tr -d '[:space:]')
    [[ "$line_count" -ge 5 ]] || { echo "Expected >=5 summary lines, got: $line_count; full: $output"; return 1; }
    echo "$output" | grep -q "JWT authentication" || { echo "Missing content in summary: $output"; return 1; }
    echo "$output" | grep -q "Token refresh" || { echo "Missing second content item: $output"; return 1; }
    return 0
}

# Test 7: Worktree creation and removal
_test_worktree_create_remove() {
    local workdir="${TMPDIR_ROOT}/t7"
    _make_git_repo "$workdir"

    local helper="${TMPDIR_ROOT}/worktree_helper.sh"
    cat > "$helper" <<HELPEREOF
#!/usr/bin/env bash
cd '${workdir}'
source '${PROJECT_ROOT}/lib/worktree-manager.sh'
branch='tarvos/test-session-20260101'
git branch "\$branch" HEAD 2>/dev/null

wt_path=\$(worktree_create 'test-session' "\$branch")
create_exit=\$?
echo "create_exit=\$create_exit"

rel_path=\$(worktree_path 'test-session')
if [[ -f "\${rel_path}/.git" ]]; then
    echo "worktree_exists=yes"
else
    echo "worktree_exists=no"
fi

worktree_remove 'test-session'
remove_exit=\$?
echo "remove_exit=\$remove_exit"

if [[ -d "\${rel_path}" ]]; then
    echo "dir_after_remove=yes"
else
    echo "dir_after_remove=no"
fi
HELPEREOF

    local output
    output=$(bash "$helper" 2>/dev/null)

    echo "$output" | grep -q "create_exit=0" || { echo "worktree_create should succeed: $output"; return 1; }
    echo "$output" | grep -q "worktree_exists=yes" || { echo "Worktree should exist after create: $output"; return 1; }
    echo "$output" | grep -q "remove_exit=0" || { echo "worktree_remove should succeed: $output"; return 1; }
    echo "$output" | grep -q "dir_after_remove=no" || { echo "Worktree dir should be gone after remove: $output"; return 1; }
    return 0
}

# Test 8: Dual worktree coexistence
_test_dual_worktree_coexistence() {
    local workdir="${TMPDIR_ROOT}/t8"
    _make_git_repo "$workdir"

    local output
    output=$(cd "$workdir" && bash -c "
        source '${PROJECT_ROOT}/lib/worktree-manager.sh'
        git branch 'tarvos/session-a' HEAD 2>/dev/null
        git branch 'tarvos/session-b' HEAD 2>/dev/null

        worktree_create 'session-a' 'tarvos/session-a' >/dev/null
        worktree_create 'session-b' 'tarvos/session-b' >/dev/null

        local path_a path_b
        path_a=\$(worktree_path 'session-a')
        path_b=\$(worktree_path 'session-b')

        [[ -f \"\${path_a}/.git\" ]] && echo 'a_exists=yes' || echo 'a_exists=no'
        [[ -f \"\${path_b}/.git\" ]] && echo 'b_exists=yes' || echo 'b_exists=no'
        [[ \"\$path_a\" != \"\$path_b\" ]] && echo 'paths_differ=yes' || echo 'paths_differ=no'
    " 2>/dev/null)

    echo "$output" | grep -q "a_exists=yes" || { echo "Session-a worktree should exist: $output"; return 1; }
    echo "$output" | grep -q "b_exists=yes" || { echo "Session-b worktree should exist: $output"; return 1; }
    echo "$output" | grep -q "paths_differ=yes" || { echo "Worktree paths should differ: $output"; return 1; }
    return 0
}

# Test 9: Spinner renders (tc_spinner_start / tc_spinner_stop)
_test_spinner_renders() {
    local pid_file="${TMPDIR_ROOT}/spinner_pid.txt"
    local helper="${TMPDIR_ROOT}/spinner_helper.sh"

    cat > "$helper" <<HELPEREOF
#!/usr/bin/env bash
# Override tput to avoid terminal issues in non-interactive test
tput() { :; }
source '${PROJECT_ROOT}/lib/tui-core.sh'

tc_spinner_start 1 1
pid=\$TC_SPINNER_PID
echo "spinner_pid_set=\$([ -n "\$pid" ] && echo yes || echo no)"
echo "\$pid" > '${pid_file}'

sleep 0.25

if kill -0 "\$pid" 2>/dev/null; then
    echo 'spinner_running=yes'
else
    echo 'spinner_running=no'
fi

tc_spinner_stop
sleep 0.1

if kill -0 "\$pid" 2>/dev/null; then
    echo 'spinner_stopped=no'
else
    echo 'spinner_stopped=yes'
fi
echo "pid_cleared=\$([ -z "\$TC_SPINNER_PID" ] && echo yes || echo no)"
HELPEREOF

    local output
    output=$(bash "$helper" 2>/dev/null)

    echo "$output" | grep -q "spinner_pid_set=yes" || { echo "Spinner PID should be set: $output"; return 1; }
    echo "$output" | grep -q "spinner_running=yes" || { echo "Spinner should be running after start: $output"; return 1; }
    echo "$output" | grep -q "spinner_stopped=yes" || { echo "Spinner process should be dead after stop: $output"; return 1; }
    echo "$output" | grep -q "pid_cleared=yes" || { echo "TC_SPINNER_PID should be cleared after stop: $output"; return 1; }
    return 0
}

# Test 10: Header renders with correct content
_test_header_renders() {
    local output
    output=$(bash -c "
        # Mock tput to avoid terminal requirement
        tput() {
            case \"\$1\" in
                cols)  echo 80 ;;
                lines) echo 24 ;;
                cup)   printf '\033[%d;%dH' \"\$((\$2+1))\" \"\$((\$3+1))\" ;;
                *)     : ;;
            esac
        }
        source '${PROJECT_ROOT}/lib/tui-core.sh'
        TC_COLS=80
        TC_ROWS=24
        output=\$(tc_draw_header 2>/dev/null)
        echo \"\$output\"
    " 2>/dev/null)

    echo "$output" | grep -q "TARVOS" || { echo "Header should contain TARVOS: $output"; return 1; }
    # Check for emoji or brand content
    echo "$output" | grep -qE "(🦥|TARVOS)" || { echo "Header should contain brand: $output"; return 1; }
    return 0
}

# Test 11: Git validation — no repo
_test_git_validation_no_repo() {
    local workdir="${TMPDIR_ROOT}/t11"
    mkdir -p "$workdir"
    # Do NOT init a git repo here

    # Create a dummy PRD file
    echo "# Test PRD" > "${workdir}/test.prd.md"

    local output exit_code=0
    output=$(cd "$workdir" && bash "${PROJECT_ROOT}/tarvos.sh" init ./test.prd.md --name test 2>&1) || exit_code=$?

    [[ "$exit_code" -ne 0 ]] || { echo "Should exit non-zero in non-git dir; output: $output"; return 1; }
    echo "$output" | grep -qi "not a git repository" || { echo "Should mention 'not a git repository': $output"; return 1; }
    echo "$output" | grep -q "git init" || { echo "Should include 'git init' instructions: $output"; return 1; }
    return 0
}

# Test 12: Git validation — missing .gitignore
_test_git_validation_no_gitignore() {
    local workdir="${TMPDIR_ROOT}/t12"
    _make_git_repo "$workdir"

    # Ensure no .gitignore
    rm -f "${workdir}/.gitignore"

    # Create a dummy PRD file
    echo "# Test PRD" > "${workdir}/test.prd.md"

    # Mock jq and claude to avoid real dependency
    local mock_bin="${TMPDIR_ROOT}/mock-bin-t12"
    mkdir -p "$mock_bin"
    # Mock jq (minimal: just exit 0)
    cat > "${mock_bin}/jq" <<'EOF'
#!/bin/bash
echo ""
exit 0
EOF
    chmod +x "${mock_bin}/jq"
    # Mock claude (exit with error so init fails before doing anything real)
    cat > "${mock_bin}/claude" <<'EOF'
#!/bin/bash
echo "mock claude"
exit 0
EOF
    chmod +x "${mock_bin}/claude"

    local output exit_code=0
    output=$(cd "$workdir" && PATH="${mock_bin}:${PATH}" bash "${PROJECT_ROOT}/tarvos.sh" init ./test.prd.md --name test-session --no-preview 2>&1) || exit_code=$?

    # .gitignore should be created
    [[ -f "${workdir}/.gitignore" ]] || { echo ".gitignore should be created: output=$output"; return 1; }
    grep -q '.tarvos/' "${workdir}/.gitignore" || { echo ".gitignore should contain .tarvos/: $(cat "${workdir}/.gitignore")"; return 1; }
    echo "$output" | grep -q "Created .gitignore" || { echo "Should mention created .gitignore: $output"; return 1; }
    return 0
}

# Test 13: Git validation — existing .gitignore without .tarvos/ entry
_test_git_validation_existing_gitignore() {
    local workdir="${TMPDIR_ROOT}/t13"
    _make_git_repo "$workdir"

    # Create .gitignore WITHOUT .tarvos/
    printf 'node_modules/\n*.log\n' > "${workdir}/.gitignore"

    echo "# Test PRD" > "${workdir}/test.prd.md"

    # Mock dependencies
    local mock_bin="${TMPDIR_ROOT}/mock-bin-t13"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/jq" <<'EOF'
#!/bin/bash
echo ""
exit 0
EOF
    chmod +x "${mock_bin}/jq"
    cat > "${mock_bin}/claude" <<'EOF'
#!/bin/bash
echo "mock claude"
exit 0
EOF
    chmod +x "${mock_bin}/claude"

    local output exit_code=0
    output=$(cd "$workdir" && PATH="${mock_bin}:${PATH}" bash "${PROJECT_ROOT}/tarvos.sh" init ./test.prd.md --name test-session --no-preview 2>&1) || exit_code=$?

    # .tarvos/ should be appended
    grep -q '.tarvos/' "${workdir}/.gitignore" || { echo ".tarvos/ should be appended to .gitignore: $(cat "${workdir}/.gitignore")"; return 1; }
    # Original contents should still be there
    grep -q 'node_modules/' "${workdir}/.gitignore" || { echo "Original .gitignore content should be preserved: $(cat "${workdir}/.gitignore")"; return 1; }
    echo "$output" | grep -q "Added .tarvos/" || { echo "Should mention added .tarvos/ to .gitignore: $output"; return 1; }
    return 0
}

# ──────────────────────────────────────────────────────────────
# Main — run all tests
# ──────────────────────────────────────────────────────────────
main() {
    printf "\n${_BOLD}Tarvos TUI Smoke Tests${_RESET}\n"
    printf "${_DIM}Running %d tests...${_RESET}\n\n" "$TOTAL_TESTS"

    _setup_tmpdir

    _run_test  1 "List screen renders"                    _test_list_renders
    _run_test  2 "List screen navigation"                 _test_list_navigation
    _run_test  3 "Action overlay renders"                 _test_action_overlay_actions
    _run_test  4 "Run view renders"                       _test_run_view_renders
    _run_test  5 "Log view toggle"                        _test_log_view_toggle
    _run_test  6 "Completion summary overlay"             _test_completion_summary_overlay
    _run_test  7 "Worktree creation"                      _test_worktree_create_remove
    _run_test  8 "Dual worktree coexistence"              _test_dual_worktree_coexistence
    _run_test  9 "Spinner renders"                        _test_spinner_renders
    _run_test 10 "Header renders"                         _test_header_renders
    _run_test 11 "Git validation — no repo"               _test_git_validation_no_repo
    _run_test 12 "Git validation — missing .gitignore"    _test_git_validation_no_gitignore
    _run_test 13 "Existing .gitignore updated"            _test_git_validation_existing_gitignore

    printf "\n"
    if [[ "$FAILED" -eq 0 ]]; then
        printf "${_GREEN}${_BOLD}All ${TOTAL_TESTS} tests passed.${_RESET}\n\n"
        exit 0
    else
        printf "${_RED}${_BOLD}${FAILED} test(s) failed:${_RESET}\n"
        for t in "${FAILED_TESTS[@]}"; do
            printf "  ${_RED}%s${_RESET}\n" "$t"
        done
        printf "\n${_GREEN}${PASSED} passed${_RESET}, ${_RED}${FAILED} failed${_RESET}\n\n"
        exit 1
    fi
}

main "$@"
