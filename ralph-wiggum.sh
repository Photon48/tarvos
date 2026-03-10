#!/usr/bin/env bash
set -uo pipefail
# NOTE: set -e intentionally omitted — it's incompatible with complex TUI rendering
# and bash arithmetic. Errors are handled explicitly where needed.

# Ralph Wiggum - AI Coding Agent Orchestrator
# Runs Claude Code agents in a loop on a single master plan (.prd.md)
# Each agent works on one phase, then hands off to a fresh agent via progress.md

# Resolve script directory (where lib/ and protocol live)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clear Claude Code env vars so child claude instances don't think they're nested sessions.
# Ralph Wiggum spawns independent Claude agents, not nested sessions.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# Source library modules
source "${SCRIPT_DIR}/lib/log-manager.sh"
source "${SCRIPT_DIR}/lib/prompt-builder.sh"
source "${SCRIPT_DIR}/lib/signal-detector.sh"
source "${SCRIPT_DIR}/lib/context-monitor.sh"

# Defaults
DEFAULT_TOKEN_LIMIT=100000
DEFAULT_MAX_LOOPS=50
MAX_RETRIES=2

# Global PID of the running Claude subprocess (so traps can kill it)
CLAUDE_PID=""

# Clean shutdown: kill claude, restore terminal, exit
shutdown() {
    local exit_code="${1:-130}"
    # Kill claude if running
    if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill -TERM "$CLAUDE_PID" 2>/dev/null
        sleep 0.5
        kill -KILL "$CLAUDE_PID" 2>/dev/null || true
        wait "$CLAUDE_PID" 2>/dev/null || true
    fi
    CLAUDE_PID=""
    tui_cleanup
    echo ""
    echo "Ralph Wiggum stopped."
    exit "$exit_code"
}

# Usage
usage() {
    cat <<EOF
Usage: $(basename "$0") <path-to-prd.md> [options]

Options:
  --continue          Resume from existing progress.md instead of starting fresh
  --token-limit <N>   Token limit before forcing handoff (default: ${DEFAULT_TOKEN_LIMIT})
  --max-loops <N>     Maximum number of loop iterations (default: ${DEFAULT_MAX_LOOPS})
  -h, --help          Show this help message

Example:
  $(basename "$0") ./my-project/.prd.md
  $(basename "$0") ./my-project/.prd.md --continue
  $(basename "$0") /path/to/project/.prd.md --token-limit 80000 --max-loops 20
EOF
    exit 0
}

# Parse arguments
parse_args() {
    PRD_FILE=""
    TOKEN_LIMIT="$DEFAULT_TOKEN_LIMIT"
    MAX_LOOPS="$DEFAULT_MAX_LOOPS"
    CONTINUE_MODE=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            --continue)
                CONTINUE_MODE=1
                shift
                ;;
            --token-limit)
                TOKEN_LIMIT="$2"
                shift 2
                ;;
            --max-loops)
                MAX_LOOPS="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "$PRD_FILE" ]]; then
                    PRD_FILE="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$PRD_FILE" ]]; then
        log_error "Missing required argument: <path-to-prd.md>"
        usage
    fi
}

# Validate environment
validate_environment() {
    # Check PRD file exists
    if [[ ! -f "$PRD_FILE" ]]; then
        log_error "PRD file not found: $PRD_FILE"
        exit 1
    fi

    # Resolve to absolute path
    PRD_FILE="$(cd "$(dirname "$PRD_FILE")" && pwd)/$(basename "$PRD_FILE")"

    # Protocol file
    PROTOCOL_FILE="${SCRIPT_DIR}/ralph-wiggum-protocol.md"
    if [[ ! -f "$PROTOCOL_FILE" ]]; then
        log_error "Protocol file not found: $PROTOCOL_FILE"
        exit 1
    fi

    # Project directory = where the script was invoked (CWD), not where the PRD lives
    PROJECT_DIR="$(pwd)"

    # Check for jq
    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: sudo apt install jq"
        exit 1
    fi

    # Check for claude CLI
    if ! command -v claude &>/dev/null; then
        log_error "claude CLI is required but not found in PATH"
        exit 1
    fi
}

# Run a single Claude agent iteration
# Args: $1 = loop number
# Returns: 0 on success (signal detected), 1 on failure
# Sets global: DETECTED_SIGNAL, ITERATION_TOKENS
run_iteration() {
    local loop_num="$1"
    DETECTED_SIGNAL=""
    ITERATION_TOKENS=0

    local raw_log text_output stderr_log
    raw_log=$(get_raw_log "$loop_num")
    text_output=$(mktemp)
    stderr_log=$(get_stderr_log "$loop_num")

    # Build the prompt
    local prompt
    prompt=$(build_prompt "$PRD_FILE" "$PROTOCOL_FILE" "$PROJECT_DIR")

    log_info "Launching Claude agent..."

    # Reset token counters
    reset_token_counters

    # Launch Claude and process stream
    # Use a FIFO to capture PID while streaming
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"

    # Start Claude in background, writing to FIFO
    claude -p "$prompt" \
        --dangerously-skip-permissions \
        --verbose \
        --output-format stream-json \
        > "$fifo" 2>"$stderr_log" &
    CLAUDE_PID=$!

    # Process the stream (reads from FIFO)
    local stream_exit=0
    process_stream "$TOKEN_LIMIT" "$loop_num" "$raw_log" "$text_output" < "$fifo" || stream_exit=$?

    # Clean up FIFO
    rm -f "$fifo"

    # Handle context limit hit
    if (( stream_exit == 1 )) || (( CONTEXT_LIMIT_HIT )); then
        tui_set_status "CONTEXT_LIMIT"
        log_warning "Context limit reached ($(get_total_tokens) tokens >= ${TOKEN_LIMIT})"

        # Kill the running Claude process
        kill_claude_process "$CLAUDE_PID"
        CLAUDE_PID=""

        # Run continuation session to get progress.md
        tui_set_status "CONTINUATION"
        tui_set_phase_info "Writing progress.md (continuation)..."
        local continuation_prompt
        continuation_prompt=$(build_context_limit_prompt)
        run_continuation_session "$continuation_prompt" "$raw_log" "$text_output"
    else
        # Wait for Claude to finish normally
        wait "$CLAUDE_PID" 2>/dev/null
        local claude_exit=$?
        CLAUDE_PID=""

        # Report if claude failed or produced no output
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

    # Detect signal from accumulated text
    local accumulated_text
    accumulated_text=$(cat "$text_output" 2>/dev/null || echo "")
    DETECTED_SIGNAL=$(detect_signal "$accumulated_text")

    # Clean up temp file
    rm -f "$text_output"

    if is_valid_signal "$DETECTED_SIGNAL"; then
        return 0
    else
        return 1
    fi
}

# Ensure progress.md exists after an iteration
# Args: none (uses PROJECT_DIR global)
# Returns: 0 if progress.md exists, 1 if recovery failed
ensure_progress_file() {
    if [[ -f "${PROJECT_DIR}/progress.md" ]]; then
        return 0
    fi

    log_warning "progress.md not found after iteration"
    tui_set_status "RECOVERY"
    tui_set_phase_info "Recovering progress.md..."

    # Try recovery session
    local recovery_prompt
    recovery_prompt=$(build_recovery_prompt "$PROJECT_DIR")
    run_recovery_session "$recovery_prompt" "$PROJECT_DIR"
    return $?
}

# Main loop
main() {
    parse_args "$@"
    validate_environment

    # Change to project directory
    cd "$PROJECT_DIR"

    # Unless --continue, remove stale progress.md from previous runs
    if (( CONTINUE_MODE )); then
        if [[ -f "${PROJECT_DIR}/progress.md" ]]; then
            log_info "Continuing from existing progress.md"
        else
            log_warning "No progress.md found — starting fresh"
        fi
    else
        if [[ -f "${PROJECT_DIR}/progress.md" ]]; then
            rm -f "${PROJECT_DIR}/progress.md"
        fi
    fi

    # Initialize logging
    init_logging "$PROJECT_DIR"

    # Initialize TUI dashboard
    tui_init "$MAX_LOOPS" "$TOKEN_LIMIT"

    # Set up signal traps — these use the global shutdown() which kills CLAUDE_PID + cleans TUI
    trap 'shutdown 130' INT
    trap 'shutdown 143' TERM
    trap 'tui_cleanup' EXIT

    local start_time
    start_time=$(date +%s)

    if (( CONTINUE_MODE )); then
        tui_set_phase_info "Continuing from progress.md..."
    else
        tui_set_phase_info "Initializing..."
    fi
    log_info "PRD: ${PRD_FILE}"
    log_info "Project: ${PROJECT_DIR}"
    log_info "Token limit: ${TOKEN_LIMIT}"
    if (( CONTINUE_MODE )); then
        log_info "Mode: continue"
    fi
    log_info "Logs: ${LOG_DIR}"

    local loop_num=0
    local final_signal=""
    local consecutive_failures=0

    while (( loop_num < MAX_LOOPS )); do
        (( loop_num++ ))

        log_iteration_header "$loop_num" "$MAX_LOOPS"

        local iter_start
        iter_start=$(date +%s)

        # Run the iteration
        local iter_exit=0
        run_iteration "$loop_num" || iter_exit=$?

        local iter_end
        iter_end=$(date +%s)
        local iter_duration=$(( iter_end - iter_start ))
        local duration_str
        duration_str=$(format_duration "$iter_duration")

        # Handle results
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
            # Try to ensure progress.md exists before retry
            ensure_progress_file || true
        fi
    done

    # Check if we hit max loops
    if (( loop_num >= MAX_LOOPS )) && [[ "$final_signal" != "ALL_PHASES_COMPLETE" ]]; then
        log_warning "Max loops (${MAX_LOOPS}) reached without ALL_PHASES_COMPLETE"
        final_signal="${final_signal:-MAX_LOOPS_REACHED}"
    fi

    # Final signal default
    final_signal="${final_signal:-UNKNOWN}"

    # Print final summary
    log_final_summary "$loop_num" "$final_signal" "$start_time"

    # Exit code
    if [[ "$final_signal" == "ALL_PHASES_COMPLETE" ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main with all arguments
main "$@"
