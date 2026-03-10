#!/usr/bin/env bash
set -uo pipefail
# NOTE: set -e intentionally omitted — it's incompatible with complex TUI rendering
# and bash arithmetic. Errors are handled explicitly where needed.

# Tarvos - AI Coding Agent Orchestrator
# Runs Claude Code agents in a loop on a single master plan (.prd.md)
# Each agent works on one phase, then hands off to a fresh agent via progress.md
#
# Usage:
#   tarvos init <prd-path> [--token-limit N] [--max-loops N]
#   tarvos begin [--continue]

# Resolve script directory (where lib/ and protocol live)
# Dereference symlinks so SCRIPT_DIR always points to the real repo directory,
# not the directory containing the symlink (e.g. /usr/local/bin).
_TARVOS_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_TARVOS_SOURCE" ]]; do
    _TARVOS_SOURCE="$(readlink "$_TARVOS_SOURCE")"
done
SCRIPT_DIR="$(cd "$(dirname "$_TARVOS_SOURCE")" && pwd)"
unset _TARVOS_SOURCE

# Clear Claude Code env vars so child claude instances don't think they're nested sessions.
# Tarvos spawns independent Claude agents, not nested sessions.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# ──────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────
DEFAULT_TOKEN_LIMIT=100000
DEFAULT_MAX_LOOPS=50
MAX_RETRIES=2

# Config directory / file (in the user's project repo CWD)
TARVOS_DIR=".tarvos"
TARVOS_CONFIG=".tarvos/config"

# Global PID of the running Claude subprocess (so traps can kill it)
CLAUDE_PID=""

# ──────────────────────────────────────────────────────────────
# Usage helpers
# ──────────────────────────────────────────────────────────────
usage_init() {
    cat <<EOF
Usage: tarvos init <path-to-prd.md> --name <session-name> [options]

Options:
  --name <name>       Session name (required, alphanumeric + hyphens)
  --token-limit <N>   Token limit before forcing handoff (default: ${DEFAULT_TOKEN_LIMIT})
  --max-loops <N>     Maximum number of loop iterations (default: ${DEFAULT_MAX_LOOPS})
  --no-preview        Skip the AI preview and write config immediately
  -h, --help          Show this help message

Example:
  tarvos init ./my-project.prd.md --name auth-feature
  tarvos init /path/to/project.prd.md --name bugfix --token-limit 80000 --max-loops 20
  tarvos init ./plan.md --name new-api --no-preview
EOF
    exit 0
}

usage_begin() {
    cat <<EOF
Usage: tarvos begin <session-name> [options]

Options:
  --continue          Resume from existing progress.md instead of starting fresh
  -h, --help          Show this help message

Example:
  tarvos begin auth-feature
  tarvos begin auth-feature --continue

Run \`tarvos init <prd-path> --name <name>\` first to create a session.
EOF
    exit 0
}

usage_root() {
    cat <<EOF
Usage: tarvos <command> [options]

Commands:
  init <prd-path> --name <name>   Create a new session
  begin <name>                    Run session agent loop
  begin <name> --continue         Resume from existing progress.md

Run \`tarvos <command> --help\` for command-specific options.
EOF
    exit 0
}

# ──────────────────────────────────────────────────────────────
# tarvos init
# ──────────────────────────────────────────────────────────────
cmd_init() {
    local prd_file=""
    local session_name=""
    local token_limit="$DEFAULT_TOKEN_LIMIT"
    local max_loops="$DEFAULT_MAX_LOOPS"
    local no_preview=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)     usage_init ;;
            --name)        session_name="$2"; shift 2 ;;
            --token-limit) token_limit="$2"; shift 2 ;;
            --max-loops)   max_loops="$2";   shift 2 ;;
            --no-preview)  no_preview=1; shift ;;
            -*)
                echo "tarvos init: unknown option: $1" >&2
                usage_init
                ;;
            *)
                if [[ -z "$prd_file" ]]; then
                    prd_file="$1"
                else
                    echo "tarvos init: unexpected argument: $1" >&2
                    usage_init
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$prd_file" ]]; then
        echo "tarvos init: missing required argument <path-to-prd.md>" >&2
        usage_init
    fi

    if [[ -z "$session_name" ]]; then
        echo "tarvos init: missing required option --name <session-name>" >&2
        usage_init
    fi

    # Validate PRD exists
    if [[ ! -f "$prd_file" ]]; then
        echo "tarvos init: PRD file not found: $prd_file" >&2
        exit 1
    fi

    # Resolve to absolute path
    prd_file="$(cd "$(dirname "$prd_file")" && pwd)/$(basename "$prd_file")"

    # Validate dependencies
    if ! command -v jq &>/dev/null; then
        echo "tarvos init: jq is required but not installed. Install with: brew install jq" >&2
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo "tarvos init: claude CLI is required but not found in PATH" >&2
        exit 1
    fi

    local project_dir
    project_dir="$(pwd)"

    # Source session manager and create session
    source "${SCRIPT_DIR}/lib/session-manager.sh"

    mkdir -p "${TARVOS_DIR}"

    session_init "$session_name" "$prd_file" "$token_limit" "$max_loops" || exit 1

    if (( no_preview )); then
        _init_display_no_preview "$prd_file" "$project_dir" "$token_limit" "$max_loops" "$session_name"
    else
        source "${SCRIPT_DIR}/lib/prd-preview.sh"
        _init_display_with_preview "$prd_file" "$project_dir" "$token_limit" "$max_loops" "$session_name"
    fi
}

# Display: --no-preview path (fast grep-based fallback)
_init_display_no_preview() {
    local prd_file="$1" project_dir="$2" token_limit="$3" max_loops="$4" session_name="${5:-}"

    local BOLD='\033[1m' RESET='\033[0m' DIM='\033[2m' GREEN='\033[0;32m'

    # Best-effort heading extraction
    local units=()
    while IFS= read -r line; do
        units+=("$line")
    done < <(grep -E '^#{1,3} ' "$prd_file" 2>/dev/null | sed -E 's/^#{1,3}[[:space:]]*//' | head -20)

    echo ""
    echo -e "  ${BOLD}Tarvos — AI Coding Agent Orchestrator${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
    if [[ -n "$session_name" ]]; then
        printf "  ${BOLD}%-14s${RESET}%s\n" "Session:" "$session_name"
    fi
    printf "  ${BOLD}%-14s${RESET}%s\n" "PRD:" "$prd_file"
    printf "  ${BOLD}%-14s${RESET}%s\n" "Project:" "$project_dir"
    printf "  ${BOLD}%-14s${RESET}" "Token limit:"
    printf "%'.0f per agent\n" "$token_limit" 2>/dev/null || printf "%s per agent\n" "$token_limit"
    printf "  ${BOLD}%-14s${RESET}%s\n" "Max loops:" "$max_loops"

    if [[ ${#units[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Headings found:${RESET}"
        local i=1
        for unit in "${units[@]}"; do
            printf "    %d. %s\n" "$i" "$unit"
            (( i++ ))
        done
    fi

    echo ""
    if [[ -n "$session_name" ]]; then
        echo -e "  ${DIM}Session created: .tarvos/sessions/${session_name}/${RESET}"
    else
        echo -e "  ${DIM}Config written to: .tarvos/config${RESET}"
    fi
    echo -e "  ${DIM}Tip: add .tarvos/ to your .gitignore${RESET}"
    echo ""
    if [[ -n "$session_name" ]]; then
        echo -e "  ${GREEN}${BOLD}Ready.${RESET} Run \`tarvos begin ${session_name}\` to start."
    else
        echo -e "  ${GREEN}${BOLD}Ready.${RESET} Run \`tarvos begin\` to start."
    fi
    echo ""
}

# Display: AI-powered preview path
_init_display_with_preview() {
    local prd_file="$1" project_dir="$2" token_limit="$3" max_loops="$4" session_name="${5:-}"

    local DIM='\033[2m' RESET='\033[0m'

    printf "  Analysing PRD...${DIM} (run with --no-preview to skip)${RESET}\n"

    local raw_preview
    raw_preview=$(run_prd_preview "$prd_file")

    if [[ -z "$raw_preview" ]]; then
        # claude call failed — fall back gracefully
        echo "  (Preview unavailable — falling back to heading scan)"
        _init_display_no_preview "$prd_file" "$project_dir" "$token_limit" "$max_loops" "$session_name"
        return
    fi

    parse_preview_output "$raw_preview"
    display_preview "$prd_file" "$project_dir" "$token_limit" "$max_loops" "$session_name"
}

# ──────────────────────────────────────────────────────────────
# tarvos begin — reads config then runs the agent loop
# ──────────────────────────────────────────────────────────────
cmd_begin() {
    local session_name=""
    local continue_mode=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_begin ;;
            --continue) continue_mode=1; shift ;;
            -*)
                echo "tarvos begin: unknown option: $1" >&2
                usage_begin
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos begin: unexpected argument: $1" >&2
                    usage_begin
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos begin: missing required argument <session-name>" >&2
        usage_begin
    fi

    # Validate dependencies
    if ! command -v jq &>/dev/null; then
        echo "tarvos begin: jq is required but not installed." >&2
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo "tarvos begin: claude CLI not found in PATH." >&2
        exit 1
    fi

    # Source session manager and load session
    source "${SCRIPT_DIR}/lib/session-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos begin: session '${session_name}' not found. Run \`tarvos init <prd-path> --name ${session_name}\` first." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    # Guard against running a completed or already-running session
    case "$SESSION_STATUS" in
        done)
            echo "tarvos begin: session '${session_name}' is already done. Use \`tarvos accept\` or \`tarvos reject\`." >&2
            exit 1
            ;;
        running)
            echo "tarvos begin: session '${session_name}' is already running." >&2
            exit 1
            ;;
        failed)
            echo "tarvos begin: session '${session_name}' has failed. Use \`tarvos reject\` to remove it." >&2
            exit 1
            ;;
    esac

    local PRD_FILE="$SESSION_PRD_FILE"
    local TOKEN_LIMIT="$SESSION_TOKEN_LIMIT"
    local MAX_LOOPS="$SESSION_MAX_LOOPS"

    # Validate PRD still exists
    if [[ ! -f "$PRD_FILE" ]]; then
        echo "tarvos begin: PRD file not found: $PRD_FILE" >&2
        echo "Re-run \`tarvos init <prd-path> --name ${session_name}\` with the correct path." >&2
        exit 1
    fi

    # Protocol file (SKILL.md in the tarvos-skill folder)
    local PROTOCOL_FILE="${SCRIPT_DIR}/tarvos-skill/SKILL.md"
    if [[ ! -f "$PROTOCOL_FILE" ]]; then
        echo "tarvos begin: skill file not found: $PROTOCOL_FILE" >&2
        exit 1
    fi

    # Project directory = CWD at invocation time
    local PROJECT_DIR
    PROJECT_DIR="$(pwd)"

    # Source library modules (now that we know everything is valid)
    source "${SCRIPT_DIR}/lib/log-manager.sh"
    source "${SCRIPT_DIR}/lib/prompt-builder.sh"
    source "${SCRIPT_DIR}/lib/signal-detector.sh"
    source "${SCRIPT_DIR}/lib/context-monitor.sh"

    # Mark session as running
    session_set_status "$session_name" "running"
    session_mark_started "$session_name"

    # ── Run the agent loop ──────────────────────────────────────
    CONTINUE_MODE="$continue_mode"
    CURRENT_SESSION_NAME="$session_name"
    run_agent_loop "$PRD_FILE" "$PROTOCOL_FILE" "$PROJECT_DIR" "$TOKEN_LIMIT" "$MAX_LOOPS" "$CONTINUE_MODE" "$session_name"
}

# ──────────────────────────────────────────────────────────────
# Clean shutdown: kill claude, restore terminal, exit
# ──────────────────────────────────────────────────────────────
shutdown() {
    local exit_code="${1:-130}"
    if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill -TERM "$CLAUDE_PID" 2>/dev/null
        sleep 0.5
        kill -KILL "$CLAUDE_PID" 2>/dev/null || true
        wait "$CLAUDE_PID" 2>/dev/null || true
    fi
    CLAUDE_PID=""
    tui_cleanup
    echo ""
    echo "Tarvos stopped."
    exit "$exit_code"
}

# ──────────────────────────────────────────────────────────────
# Run a single Claude agent iteration
# Args: $1 = loop number
# Returns: 0 on success (signal detected), 1 on failure
# Sets global: DETECTED_SIGNAL, ITERATION_TOKENS
# ──────────────────────────────────────────────────────────────
run_iteration() {
    local loop_num="$1"
    DETECTED_SIGNAL=""
    ITERATION_TOKENS=0

    local raw_log text_output stderr_log
    raw_log=$(get_raw_log "$loop_num")
    text_output=$(mktemp)
    stderr_log=$(get_stderr_log "$loop_num")

    # Build the prompt (pass session progress file if set)
    local prompt
    prompt=$(build_prompt "$PRD_FILE" "$PROTOCOL_FILE" "$PROJECT_DIR" "${PROGRESS_FILE:-}")

    log_info "Launching Claude agent..."

    # Reset token counters
    reset_token_counters

    # Launch Claude and process stream via FIFO
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"

    claude -p "$prompt" \
        --dangerously-skip-permissions \
        --verbose \
        --output-format stream-json \
        > "$fifo" 2>"$stderr_log" &
    CLAUDE_PID=$!

    local stream_exit=0
    process_stream "$TOKEN_LIMIT" "$loop_num" "$raw_log" "$text_output" < "$fifo" || stream_exit=$?

    rm -f "$fifo"

    # Handle context limit hit
    if (( stream_exit == 1 )) || (( CONTEXT_LIMIT_HIT )); then
        tui_set_status "CONTEXT_LIMIT"
        log_warning "Context limit reached ($(get_total_tokens) tokens >= ${TOKEN_LIMIT})"

        kill_claude_process "$CLAUDE_PID"
        CLAUDE_PID=""

        tui_set_status "CONTINUATION"
        tui_set_phase_info "Writing progress.md (continuation)..."
        local continuation_prompt
        continuation_prompt=$(build_context_limit_prompt)
        run_continuation_session "$continuation_prompt" "$raw_log" "$text_output"
    else
        wait "$CLAUDE_PID" 2>/dev/null
        local claude_exit=$?
        CLAUDE_PID=""

        if [[ $claude_exit -ne 0 ]]; then
            if [[ -s "$stderr_log" ]]; then
                log_error "Claude exited with code ${claude_exit}: $(head -c 300 "$stderr_log" | tr '\n' ' ')"
            else
                log_error "Claude exited with code ${claude_exit} (no stderr)"
            fi
        elif [[ ! -s "$text_output" ]]; then
            log_warning "Claude produced no text output (exit code 0)"
            if [[ -s "$stderr_log" ]]; then
                log_warning "Stderr: $(head -c 300 "$stderr_log" | tr '\n' ' ')"
            fi
        fi
    fi

    ITERATION_TOKENS=$(get_total_tokens)

    local accumulated_text
    accumulated_text=$(cat "$text_output" 2>/dev/null || echo "")
    DETECTED_SIGNAL=$(detect_signal "$accumulated_text")

    rm -f "$text_output"

    if is_valid_signal "$DETECTED_SIGNAL"; then
        return 0
    else
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────
# Ensure progress.md exists after an iteration
# Uses PROGRESS_FILE global (set per-session or defaults to project root)
# ──────────────────────────────────────────────────────────────
ensure_progress_file() {
    local progress_file="${PROGRESS_FILE:-${PROJECT_DIR}/progress.md}"

    if [[ -f "$progress_file" ]]; then
        return 0
    fi

    log_warning "progress.md not found after iteration"
    tui_set_status "RECOVERY"
    tui_set_phase_info "Recovering progress.md..."

    local recovery_prompt
    recovery_prompt=$(build_recovery_prompt "$PROJECT_DIR" "$progress_file")
    run_recovery_session "$recovery_prompt" "$PROJECT_DIR" "$progress_file"
    return $?
}

# ──────────────────────────────────────────────────────────────
# Main agent loop (called by cmd_begin after env is validated)
# ──────────────────────────────────────────────────────────────
run_agent_loop() {
    PRD_FILE="$1"
    PROTOCOL_FILE="$2"
    PROJECT_DIR="$3"
    TOKEN_LIMIT="$4"
    MAX_LOOPS="$5"
    local continue_mode="$6"
    local session_name="${7:-}"

    cd "$PROJECT_DIR"

    # Determine the progress.md location:
    # If a session is active, use session-local progress.md; otherwise fall back to project root
    local PROGRESS_FILE
    if [[ -n "$session_name" ]] && [[ -d ".tarvos/sessions/${session_name}" ]]; then
        PROGRESS_FILE=".tarvos/sessions/${session_name}/progress.md"
    else
        PROGRESS_FILE="${PROJECT_DIR}/progress.md"
    fi

    # Handle continue / fresh start
    if (( continue_mode )); then
        if [[ -f "$PROGRESS_FILE" ]]; then
            log_info "Continuing from existing progress.md"
        else
            log_warning "No progress.md found — starting fresh"
        fi
    else
        if [[ -f "$PROGRESS_FILE" ]]; then
            rm -f "$PROGRESS_FILE"
        fi
    fi

    # Initialize logging: use session logs folder if session is active
    local log_base_dir
    if [[ -n "$session_name" ]] && [[ -d ".tarvos/sessions/${session_name}" ]]; then
        log_base_dir=".tarvos/sessions/${session_name}"
    else
        log_base_dir="$PROJECT_DIR"
    fi
    init_logging "$log_base_dir"

    # Initialize TUI dashboard
    tui_init "$MAX_LOOPS" "$TOKEN_LIMIT"

    # Signal traps
    trap 'shutdown 130' INT
    trap 'shutdown 143' TERM
    trap 'tui_cleanup' EXIT

    local start_time
    start_time=$(date +%s)

    if (( continue_mode )); then
        tui_set_phase_info "Continuing from progress.md..."
    else
        tui_set_phase_info "Initializing..."
    fi

    log_info "PRD: ${PRD_FILE}"
    log_info "Project: ${PROJECT_DIR}"
    log_info "Token limit: ${TOKEN_LIMIT}"
    if [[ -n "$session_name" ]]; then
        log_info "Session: ${session_name}"
    fi
    if (( continue_mode )); then
        log_info "Mode: continue"
    fi
    log_info "Logs: ${LOG_DIR}"

    local loop_num=0
    local final_signal=""
    local consecutive_failures=0

    while (( loop_num < MAX_LOOPS )); do
        (( loop_num++ ))

        # Update session loop count if session-based
        if [[ -n "$session_name" ]]; then
            session_set_loop_count "$session_name" "$loop_num"
        fi

        log_iteration_header "$loop_num" "$MAX_LOOPS"

        local iter_start
        iter_start=$(date +%s)

        local iter_exit=0
        run_iteration "$loop_num" || iter_exit=$?

        local iter_end
        iter_end=$(date +%s)
        local iter_duration=$(( iter_end - iter_start ))
        local duration_str
        duration_str=$(format_duration "$iter_duration")

        if (( iter_exit == 0 )) && is_valid_signal "$DETECTED_SIGNAL"; then
            consecutive_failures=0
            local note=""
            if (( CONTEXT_LIMIT_HIT )); then
                note="context limit"
            fi

            log_iteration_summary "$loop_num" "$DETECTED_SIGNAL" "$ITERATION_TOKENS" "$duration_str" "$note"
            log_dashboard_entry "$loop_num" "$DETECTED_SIGNAL" "$ITERATION_TOKENS" "$duration_str" "$note"

            case "$DETECTED_SIGNAL" in
                ALL_PHASES_COMPLETE)
                    log_success "All phases complete!"
                    tui_set_phase_info "All phases complete"
                    final_signal="$DETECTED_SIGNAL"
                    if [[ -n "$session_name" ]]; then
                        session_set_status "$session_name" "done"
                        session_set_final_signal "$session_name" "$final_signal"
                    fi
                    break
                    ;;
                PHASE_COMPLETE)
                    log_success "Phase complete, starting next iteration..."
                    tui_set_phase_info "Phase complete, preparing next..."
                    ensure_progress_file
                    ;;
                PHASE_IN_PROGRESS)
                    log_info "Phase in progress, continuing in next iteration..."
                    tui_set_phase_info "In progress, preparing continuation..."
                    ensure_progress_file
                    ;;
            esac
        else
            (( consecutive_failures++ ))
            log_iteration_summary "$loop_num" "NO_SIGNAL" "$ITERATION_TOKENS" "$duration_str" "attempt ${consecutive_failures}/${MAX_RETRIES}"
            log_dashboard_entry "$loop_num" "NO_SIGNAL" "$ITERATION_TOKENS" "$duration_str" "attempt ${consecutive_failures}/${MAX_RETRIES}"

            if (( consecutive_failures > MAX_RETRIES )); then
                log_error "Max retries (${MAX_RETRIES}) exceeded. Aborting."
                final_signal="ERROR_MAX_RETRIES"
                break
            fi

            log_warning "No signal detected, retrying (attempt ${consecutive_failures}/${MAX_RETRIES})..."
            ensure_progress_file || true
        fi
    done

    # Check if we hit max loops
    if (( loop_num >= MAX_LOOPS )) && [[ "$final_signal" != "ALL_PHASES_COMPLETE" ]]; then
        log_warning "Max loops (${MAX_LOOPS}) reached without ALL_PHASES_COMPLETE"
        final_signal="${final_signal:-MAX_LOOPS_REACHED}"
    fi

    final_signal="${final_signal:-UNKNOWN}"

    # Update session final state
    if [[ -n "$session_name" ]] && [[ "$final_signal" != "ALL_PHASES_COMPLETE" ]]; then
        if [[ "$final_signal" == "ERROR_MAX_RETRIES" ]] || [[ "$final_signal" == "UNKNOWN" ]]; then
            session_set_status "$session_name" "failed"
        else
            session_set_status "$session_name" "stopped"
        fi
        session_set_final_signal "$session_name" "$final_signal"
    fi

    log_final_summary "$loop_num" "$final_signal" "$start_time"

    if [[ "$final_signal" == "ALL_PHASES_COMPLETE" ]]; then
        exit 0
    else
        exit 1
    fi
}

# ──────────────────────────────────────────────────────────────
# Entry point — dispatch on subcommand
# ──────────────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        usage_root
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        init)  cmd_init "$@" ;;
        begin) cmd_begin "$@" ;;
        -h|--help) usage_root ;;
        *)
            echo "tarvos: unknown command: ${cmd}" >&2
            echo "Run \`tarvos --help\` for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
