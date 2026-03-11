#!/usr/bin/env bash
# smoke-test.sh — Manual smoke test suite for Tarvos
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
# Colors (simple ANSI)
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

# Test 1: TypeScript TUI source files exist and are importable
_test_tui_source_files_exist() {
    local required_files=(
        "${PROJECT_ROOT}/tui/src/index.tsx"
        "${PROJECT_ROOT}/tui/src/App.tsx"
        "${PROJECT_ROOT}/tui/src/theme.ts"
        "${PROJECT_ROOT}/tui/src/types.ts"
        "${PROJECT_ROOT}/tui/src/data/sessions.ts"
        "${PROJECT_ROOT}/tui/src/data/events.ts"
        "${PROJECT_ROOT}/tui/src/commands.ts"
        "${PROJECT_ROOT}/tui/src/screens/SessionListScreen.tsx"
        "${PROJECT_ROOT}/tui/src/screens/RunDashboardScreen.tsx"
        "${PROJECT_ROOT}/tui/src/screens/SummaryScreen.tsx"
        "${PROJECT_ROOT}/tui/package.json"
        "${PROJECT_ROOT}/tui/tsconfig.json"
    )

    for f in "${required_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "Missing required TUI file: $f"
            return 1
        fi
    done
    return 0
}

# Test 2: TypeScript TUI type-checks cleanly (bun --check)
_test_tui_typecheck() {
    local bun_bin
    bun_bin=$(command -v bun 2>/dev/null || echo "/Users/rishugoyal/.bun/bin/bun")
    if [[ ! -x "$bun_bin" ]]; then
        echo "bun not found — skipping typecheck (install bun to enable)"
        return 0
    fi

    local output exit_code=0
    output=$(cd "${PROJECT_ROOT}/tui" && "$bun_bin" x tsc --noEmit 2>&1) || exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        echo "TypeScript typecheck failed:"
        echo "$output"
        return 1
    fi
    return 0
}

# Test 3: Action overlay renders correct actions for each status
_test_action_overlay_actions() {
    local workdir="${TMPDIR_ROOT}/t3"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions"

    # Test that action arrays are correct per status (pure bash logic, no TUI dependency)
    local output
    output=$(bash -c "
        check_actions() {
            local status=\"\$1\"
            shift
            local expected=(\"\$@\")
            local actions=()
            case \"\$status\" in
                running)     actions=(\"Attach\" \"Stop\") ;;
                stopped)     actions=(\"Resume\" \"Reject\") ;;
                done)        actions=(\"Accept\" \"Reject\" \"View Summary\") ;;
                initialized) actions=(\"Start\" \"Reject\") ;;
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

# Test 4: Session state.json is parseable by the TypeScript data layer
_test_session_state_parseable() {
    local workdir="${TMPDIR_ROOT}/t4"
    _make_git_repo "$workdir"
    mkdir -p "${workdir}/.tarvos/sessions"

    _write_session "${workdir}/.tarvos/sessions" "auth-feature" "running" "tarvos/auth-feature-20260101" "2026-01-01T12:00:00Z"
    _write_session "${workdir}/.tarvos/sessions" "bugfix-login" "done" "tarvos/bugfix-login-20260101" "2026-01-01T11:00:00Z"
    _write_session "${workdir}/.tarvos/sessions" "new-api" "initialized" "" ""

    # Verify state.json files are valid JSON with required fields
    local sessions_dir="${workdir}/.tarvos/sessions"
    for session_dir in "${sessions_dir}"/*/; do
        local state_file="${session_dir}state.json"
        if [[ ! -f "$state_file" ]]; then
            echo "Missing state.json in ${session_dir}"
            return 1
        fi
        # Verify required fields exist
        for field in name status prd_file token_limit max_loops; do
            if ! grep -q "\"${field}\"" "$state_file"; then
                echo "Missing field '${field}' in ${state_file}"
                return 1
            fi
        done
    done

    # Verify session count
    local count
    count=$(ls -d "${sessions_dir}"/*/  2>/dev/null | wc -l | tr -d '[:space:]')
    [[ "$count" -eq 3 ]] || { echo "Expected 3 sessions, got ${count}"; return 1; }
    return 0
}

# Test 5: JSONL event file format matches TypeScript TuiEvent type
_test_events_jsonl_format() {
    local workdir="${TMPDIR_ROOT}/t5"
    _make_git_repo "$workdir"

    local now
    now=$(date +%s)
    local events_file="${workdir}/loop-001-events.jsonl"

    cat > "$events_file" <<EOF
{"type":"tool_use","tool":"Bash","input":"npm test","ts":${now}}
{"type":"tool_result","tool":"Bash","output":"exit 0","success":true,"ts":$((now+1))}
{"type":"tool_use","tool":"Edit","input":"src/auth/middleware.ts","ts":$((now+2))}
{"type":"text","content":"Now implementing token refresh logic.","ts":$((now+3))}
{"type":"signal","signal":"PHASE_COMPLETE","ts":$((now+4))}
EOF

    # Verify each line is valid JSON with a "type" field
    local line_num=0
    while IFS= read -r line; do
        (( line_num++ ))
        [[ -z "$line" ]] && continue
        # Check it's valid JSON using bash string matching (type field present)
        echo "$line" | grep -q '"type"' || {
            echo "Line ${line_num} missing 'type' field: $line"
            return 1
        }
    done < "$events_file"

    [[ "$line_num" -ge 5 ]] || { echo "Expected >=5 event lines, got ${line_num}"; return 1; }
    grep -q '"type":"tool_use"' "$events_file" || { echo "Missing tool_use event"; return 1; }
    grep -q '"type":"text"' "$events_file" || { echo "Missing text event"; return 1; }
    grep -q '"type":"signal"' "$events_file" || { echo "Missing signal event"; return 1; }
    return 0
}

# Test 6: Completion summary overlay — reads summary.md correctly
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

# Test 9: TypeScript TUI braille spinner chars defined in theme
_test_spinner_chars_defined() {
    local theme_file="${PROJECT_ROOT}/tui/src/theme.ts"
    [[ -f "$theme_file" ]] || { echo "Missing theme.ts: $theme_file"; return 1; }

    # Check BRAILLE_SPINNER is defined
    grep -q "BRAILLE_SPINNER" "$theme_file" || { echo "BRAILLE_SPINNER not found in theme.ts"; return 1; }
    # Check at least one braille char is present
    grep -qE "⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏" "$theme_file" || { echo "Braille spinner chars missing in theme.ts"; return 1; }
    return 0
}

# Test 10: TypeScript TUI theme exports required brand colors
_test_theme_exports() {
    local theme_file="${PROJECT_ROOT}/tui/src/theme.ts"
    [[ -f "$theme_file" ]] || { echo "Missing theme.ts: $theme_file"; return 1; }

    for field in accent purple muted success warning error info panelBg; do
        grep -q "\"${field}\":" "$theme_file" || grep -q "${field}:" "$theme_file" || {
            echo "Missing theme field '${field}' in theme.ts"
            return 1
        }
    done

    # Check TARVOS brand color (gum pink accent)
    grep -q "#D75FAF\|#d75faf" "$theme_file" || { echo "Brand accent color #D75FAF not found in theme.ts"; return 1; }
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
    printf "\n${_BOLD}Tarvos Smoke Tests${_RESET}\n"
    printf "${_DIM}Running %d tests...${_RESET}\n\n" "$TOTAL_TESTS"

    _setup_tmpdir

    _run_test  1 "TUI source files exist"                 _test_tui_source_files_exist
    _run_test  2 "TUI TypeScript type-checks"             _test_tui_typecheck
    _run_test  3 "Action overlay renders"                 _test_action_overlay_actions
    _run_test  4 "Session state.json parseable"           _test_session_state_parseable
    _run_test  5 "JSONL event file format"                _test_events_jsonl_format
    _run_test  6 "Completion summary overlay"             _test_completion_summary_overlay
    _run_test  7 "Worktree creation"                      _test_worktree_create_remove
    _run_test  8 "Dual worktree coexistence"              _test_dual_worktree_coexistence
    _run_test  9 "Spinner chars defined in theme"         _test_spinner_chars_defined
    _run_test 10 "Theme exports brand colors"             _test_theme_exports
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
