#!/usr/bin/env bash
# agent-logger.sh — Logging and dashboard utilities for the Tarvos agent loop.
# Extracted from the old log-manager.sh after the bash TUI was replaced by
# the OpenTUI (TypeScript/Bun) TUI in tui/.

# ──────────────────────────────────────────────────────────────
# Colors (simple ANSI codes — no tui-core dependency)
# ──────────────────────────────────────────────────────────────
GREEN="\033[38;5;76m"
RED="\033[38;5;196m"
YELLOW="\033[38;5;214m"
MAGENTA="\033[38;5;57m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

# ──────────────────────────────────────────────────────────────
# State
# ──────────────────────────────────────────────────────────────
LOG_DIR=""
DASHBOARD_LOG=""

# History of completed iterations
declare -a HISTORY_LOOP=()
declare -a HISTORY_SIGNAL=()
declare -a HISTORY_TOKENS=()
declare -a HISTORY_DURATION=()
declare -a HISTORY_NOTE=()

# ──────────────────────────────────────────────────────────────
# Logging init
# ──────────────────────────────────────────────────────────────
init_logging() {
    local base_dir="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    if [[ "$base_dir" == *"/.tarvos/sessions/"* ]] || [[ "$base_dir" == ".tarvos/sessions/"* ]]; then
        LOG_DIR="${base_dir}/logs/run-${timestamp}"
    else
        LOG_DIR="${base_dir}/logs/tarvos/run-${timestamp}"
    fi
    mkdir -p "$LOG_DIR"
    DASHBOARD_LOG="${LOG_DIR}/dashboard.log"
    touch "$DASHBOARD_LOG"
}

get_raw_log()    { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-raw.jsonl"; }
get_usage_log()  { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-usage.log"; }
get_stderr_log() { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-stderr.log"; }
get_events_log() { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-events.jsonl"; }

# ──────────────────────────────────────────────────────────────
# Public log functions — write to stdout/dashboard log
# ──────────────────────────────────────────────────────────────
log_iteration_header() {
    local loop_num="$1"
    local max_loops="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}${RESET}  Loop ${loop_num}/${max_loops} started" >&2
    return 0
}

log_success() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}${RESET}  ${GREEN}✓${RESET}  $1" >&2
    return 0
}

log_warning() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}${RESET}  ${YELLOW}!!${RESET} $1" >&2
    return 0
}

log_error() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}${RESET}  ${RED}✗${RESET}  $1" >&2
    return 0
}

log_info() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}${RESET}  --- $1" >&2
    return 0
}

log_debug() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${DIM}${ts}      $1${RESET}" >&2
    return 0
}

log_token_progress() {
    # No-op: token progress is now shown via the OpenTUI dashboard
    return 0
}

log_iteration_summary() {
    local loop_num="$1"
    local signal="$2"
    local tokens="$3"
    local duration="$4"
    local note="${5:-}"

    HISTORY_LOOP+=("$loop_num")
    HISTORY_SIGNAL+=("$signal")
    HISTORY_TOKENS+=("$tokens")
    HISTORY_DURATION+=("$duration")
    HISTORY_NOTE+=("$note")

    log_info "Loop ${loop_num} -> ${signal} (${tokens} tok, ${duration})"
    return 0
}

log_dashboard_entry() {
    local loop_num="$1"
    local signal="$2"
    local tokens="$3"
    local duration="$4"
    local note="${5:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local loop_label
    loop_label=$(printf 'loop-%03d' "$loop_num")

    local entry="${timestamp} | ${loop_label} | $(printf '%-19s' "$signal") | tokens: $(printf '%-6s' "$tokens") | duration: ${duration}"
    if [[ -n "$note" ]]; then
        entry+=" (${note})"
    fi

    echo "$entry" >> "$DASHBOARD_LOG"
}

log_usage_snapshot() {
    local loop_num="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    local total=$(( input_tokens + output_tokens ))
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local usage_log
    usage_log=$(get_usage_log "$loop_num")
    echo "${timestamp} | input: ${input_tokens} | output: ${output_tokens} | total: ${total}" >> "$usage_log"
}

log_final_summary() {
    local total_iterations="$1"
    local final_signal="$2"
    local start_time="$3"
    local session_name="${4:-}"

    local end_time
    end_time=$(date +%s)
    local total_duration=$(( end_time - start_time ))
    local duration_str
    duration_str=$(format_duration "$total_duration")

    local status_color="$GREEN"
    local status_text="COMPLETED"
    if [[ "$final_signal" != "ALL_PHASES_COMPLETE" ]]; then
        status_color="$RED"
        status_text="STOPPED"
    fi

    echo ""
    echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${MAGENTA}  TARVOS | Final Summary${RESET}"
    echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  Status:       ${status_color}${BOLD}${status_text}${RESET}"
    echo -e "  Final signal: ${final_signal}"
    echo -e "  Iterations:   ${total_iterations}"
    echo -e "  Total time:   ${duration_str}"
    echo -e "  Logs:         ${LOG_DIR}"
    echo -e "  Dashboard:    ${DASHBOARD_LOG}"
    echo ""

    # Print iteration history table
    echo -e "${DIM}  Iteration History:${RESET}"
    local hist_count=${#HISTORY_LOOP[@]}
    local i
    for (( i=0; i<hist_count; i++ )); do
        local sig="${HISTORY_SIGNAL[$i]}"
        local sc="${GREEN}"
        case "$sig" in
            PHASE_IN_PROGRESS) sc="${YELLOW}" ;;
            NO_SIGNAL*|ERROR*) sc="${RED}" ;;
        esac
        printf "  #%-4s ${sc}%-22s${RESET} %-10s %-10s ${DIM}%s${RESET}\n" \
            "${HISTORY_LOOP[$i]}" "$sig" "${HISTORY_TOKENS[$i]}" "${HISTORY_DURATION[$i]}" "${HISTORY_NOTE[$i]}"
    done
    echo ""
}

# ──────────────────────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────────────────────
format_duration() {
    local total_seconds="$1"
    local hours=$(( total_seconds / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    if (( hours > 0 )); then
        printf '%dh%02dm%02ds' "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm%02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}
