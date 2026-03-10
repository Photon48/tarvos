#!/usr/bin/env bash
# log-manager.sh - TUI dashboard with real-time visibility into Tarvos runs

# ──────────────────────────────────────────────────────────────
# Colors & styles
# ──────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'
readonly BG_DARK='\033[48;5;235m'
readonly BG_HEADER='\033[48;5;24m'
readonly BG_SUCCESS='\033[48;5;22m'
readonly BG_WARN='\033[48;5;130m'
readonly BG_ERR='\033[48;5;52m'

# ──────────────────────────────────────────────────────────────
# State
# ──────────────────────────────────────────────────────────────
LOG_DIR=""
DASHBOARD_LOG=""

# TUI state
TUI_ENABLED=0
TUI_COLS=80
TUI_ROWS=24
CURRENT_LOOP=0
CURRENT_MAX_LOOPS=0
CURRENT_PHASE_INFO="Starting..."
CURRENT_SIGNAL=""
CURRENT_TOKEN_COUNT=0
CURRENT_TOKEN_LIMIT=100000
CURRENT_STATUS="IDLE"       # IDLE, RUNNING, CONTEXT_LIMIT, CONTINUATION, RECOVERY, DONE
RUN_START_TIME=0
ITER_START_TIME=0

# History of completed iterations (last 10)
declare -a HISTORY_LOOP=()
declare -a HISTORY_SIGNAL=()
declare -a HISTORY_TOKENS=()
declare -a HISTORY_DURATION=()
declare -a HISTORY_NOTE=()

# Activity log (last 8 lines)
declare -a ACTIVITY_LOG=()
MAX_ACTIVITY=8

# ──────────────────────────────────────────────────────────────
# Logging init
# ──────────────────────────────────────────────────────────────
init_logging() {
    local project_dir="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    LOG_DIR="${project_dir}/logs/tarvos/run-${timestamp}"
    mkdir -p "$LOG_DIR"
    DASHBOARD_LOG="${LOG_DIR}/dashboard.log"
    touch "$DASHBOARD_LOG"
}

get_raw_log()    { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-raw.jsonl"; }
get_usage_log()  { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-usage.log"; }
get_stderr_log() { echo "${LOG_DIR}/loop-$(printf '%03d' "$1")-stderr.log"; }

# ──────────────────────────────────────────────────────────────
# TUI lifecycle
# ──────────────────────────────────────────────────────────────
tui_init() {
    local max_loops="$1"
    local token_limit="$2"
    CURRENT_MAX_LOOPS="$max_loops"
    CURRENT_TOKEN_LIMIT="$token_limit"
    RUN_START_TIME=$(date +%s)

    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_ROWS=$(tput lines 2>/dev/null || echo 24)

    TUI_ENABLED=1
    tput smcup 2>/dev/null   # alternate screen
    tput civis 2>/dev/null   # hide cursor
    tput clear 2>/dev/null

    # Traps are set by the main script's shutdown() function
    # tui_cleanup is called from there
}

tui_cleanup() {
    if [[ "$TUI_ENABLED" -eq 1 ]]; then
        TUI_ENABLED=0
        tput cnorm 2>/dev/null   # show cursor
        tput rmcup 2>/dev/null   # restore screen
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────
# TUI rendering
# ──────────────────────────────────────────────────────────────

# Move to row,col (1-based)
_mv() { tput cup "$(($1 - 1))" "$(($2 - 1))" 2>/dev/null; }

# Print a full-width line padded with spaces
_line() {
    local text="$1"
    printf "%-${TUI_COLS}s" "$text"
}

# Render the entire dashboard
tui_render() {
    [[ "$TUI_ENABLED" -eq 1 ]] || return 0

    # Refresh terminal size
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_ROWS=$(tput lines 2>/dev/null || echo 24)

    local now
    now=$(date +%s)
    local elapsed=$(( now - RUN_START_TIME ))
    local elapsed_str
    elapsed_str=$(format_duration "$elapsed")

    local iter_elapsed=""
    if [[ "$ITER_START_TIME" -gt 0 ]]; then
        iter_elapsed=$(format_duration $(( now - ITER_START_TIME )))
    fi

    local row=1
    local w=$TUI_COLS
    local bar_w=$(( w - 40 ))
    [[ "$bar_w" -lt 10 ]] && bar_w=10
    [[ "$bar_w" -gt 50 ]] && bar_w=50

    # ── Header ──
    _mv $row 1
    echo -ne "${BG_HEADER}${WHITE}${BOLD}"
    _line "  TARVOS"
    row=$(( row + 1 ))
    _mv $row 1
    echo -ne "${BG_HEADER}${WHITE}"
    _line "  Autonomous AI Coding Orchestrator"
    echo -ne "${RESET}"
    row=$(( row + 1 ))

    # ── Blank separator ──
    _mv $row 1; _line ""; row=$(( row + 1 ))

    # ── Status row ──
    local status_icon status_color status_label
    case "$CURRENT_STATUS" in
        IDLE)           status_icon="○" ; status_color="${DIM}"    ; status_label="Idle" ;;
        RUNNING)        status_icon="●" ; status_color="${GREEN}"  ; status_label="Agent running" ;;
        CONTEXT_LIMIT)  status_icon="!" ; status_color="${YELLOW}" ; status_label="Context limit hit" ;;
        CONTINUATION)   status_icon="↻" ; status_color="${YELLOW}" ; status_label="Continuation session" ;;
        RECOVERY)       status_icon="⚠" ; status_color="${RED}"    ; status_label="Recovery session" ;;
        DONE)           status_icon="✓" ; status_color="${GREEN}"  ; status_label="Complete" ;;
        ERROR)          status_icon="✗" ; status_color="${RED}"    ; status_label="Error" ;;
    esac

    local pad=$((w - 30))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${BOLD}  Status: ${status_color}%s %s${RESET}%-${pad}s" "$status_icon" "$status_label" ""
    row=$(( row + 1 ))

    pad=$((w - 50))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${DIM}  Elapsed: ${RESET}%-12s${DIM}  Iteration: ${RESET}%-12s" "$elapsed_str" "${iter_elapsed:-—}"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    # ── Blank separator ──
    _mv $row 1; _line ""; row=$(( row + 1 ))

    # ── Loop / Phase info ──
    pad=$((w - 30))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${BOLD}  Loop:${RESET}  %d / %d" "$CURRENT_LOOP" "$CURRENT_MAX_LOOPS"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    pad=$((w - ${#CURRENT_PHASE_INFO} - 12))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${BOLD}  Phase:${RESET} %s" "$CURRENT_PHASE_INFO"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    # ── Blank separator ──
    _mv $row 1; _line ""; row=$(( row + 1 ))

    # ── Token progress bar ──
    local pct=0
    if [[ "$CURRENT_TOKEN_LIMIT" -gt 0 ]]; then
        pct=$(( CURRENT_TOKEN_COUNT * 100 / CURRENT_TOKEN_LIMIT ))
    fi
    [[ "$pct" -gt 100 ]] && pct=100
    local filled=$(( pct * bar_w / 100 ))
    local empty_cells=$(( bar_w - filled ))
    local bar_color="${GREEN}"
    [[ "$pct" -ge 60 ]] && bar_color="${YELLOW}"
    [[ "$pct" -ge 80 ]] && bar_color="${RED}"

    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty_cells; i++)); do bar+="░"; done

    pad=$((w - bar_w - 35))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "  ${BOLD}Tokens:${RESET} ${bar_color}[%s]${RESET} %3d%%  %d / %d" \
        "$bar" "$pct" "$CURRENT_TOKEN_COUNT" "$CURRENT_TOKEN_LIMIT"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    # ── Blank separator ──
    _mv $row 1; _line ""; row=$(( row + 1 ))

    # ── Iteration History ──
    pad=$((w - 60))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${BOLD}${DIM}  %-8s %-22s %-10s %-10s %s${RESET}" "Loop" "Signal" "Tokens" "Duration" "Note"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    local sep_w=$((w - 4))
    [[ "$sep_w" -lt 1 ]] && sep_w=1
    _mv $row 1
    printf "${DIM}  %s${RESET}" "$(printf '─%.0s' $(seq 1 "$sep_w"))"
    row=$(( row + 1 ))

    local hist_count=${#HISTORY_LOOP[@]}
    local hist_show=$(( TUI_ROWS - row - MAX_ACTIVITY - 5 ))
    [[ "$hist_show" -lt 3 ]] && hist_show=3
    local hist_start=0
    [[ "$hist_count" -gt "$hist_show" ]] && hist_start=$(( hist_count - hist_show ))

    for ((i = hist_start; i < hist_count; i++)); do
        local sig="${HISTORY_SIGNAL[$i]}"
        local sc="${GREEN}"
        case "$sig" in
            PHASE_IN_PROGRESS) sc="${YELLOW}" ;;
            NO_SIGNAL*|ERROR*) sc="${RED}" ;;
        esac
        _mv $row 1
        printf "  %-8s ${sc}%-22s${RESET} %-10s %-10s ${DIM}%s${RESET}" \
            "#${HISTORY_LOOP[$i]}" "${HISTORY_SIGNAL[$i]}" "${HISTORY_TOKENS[$i]}" "${HISTORY_DURATION[$i]}" "${HISTORY_NOTE[$i]}"
        printf "%-${pad}s" ""
        row=$(( row + 1 ))
    done

    # Fill remaining history space with blanks
    local j
    for ((j = hist_count - hist_start; j < hist_show; j++)); do
        _mv $row 1; _line ""
        row=$(( row + 1 ))
    done

    # ── Blank separator ──
    _mv $row 1; _line ""; row=$(( row + 1 ))

    # ── Activity Log ──
    pad=$((w - 12))
    [[ "$pad" -lt 1 ]] && pad=1
    _mv $row 1
    printf "${BOLD}${DIM}  Activity${RESET}"
    printf "%-${pad}s" ""
    row=$(( row + 1 ))

    _mv $row 1
    printf "${DIM}  %s${RESET}" "$(printf '─%.0s' $(seq 1 "$sep_w"))"
    row=$(( row + 1 ))

    local act_count=${#ACTIVITY_LOG[@]}
    local act_start=0
    local remaining_rows=$(( TUI_ROWS - row ))
    local act_show=$remaining_rows
    [[ "$act_show" -gt "$MAX_ACTIVITY" ]] && act_show=$MAX_ACTIVITY
    [[ "$act_show" -lt 0 ]] && act_show=0
    [[ "$act_count" -gt "$act_show" ]] && act_start=$(( act_count - act_show ))

    for ((i = act_start; i < act_count; i++)); do
        local entry_len=${#ACTIVITY_LOG[$i]}
        pad=$((w - entry_len - 4))
        [[ "$pad" -lt 1 ]] && pad=1
        _mv $row 1
        printf "  ${DIM}%s${RESET}" "${ACTIVITY_LOG[$i]}"
        printf "%-${pad}s" ""
        row=$(( row + 1 ))
    done

    # Fill remaining rows
    while [[ "$row" -le "$TUI_ROWS" ]]; do
        _mv $row 1; _line ""
        row=$(( row + 1 ))
    done

    return 0
}

# ──────────────────────────────────────────────────────────────
# TUI state update helpers
# ──────────────────────────────────────────────────────────────

tui_set_status() {
    CURRENT_STATUS="$1"
    tui_render
}

tui_set_loop() {
    CURRENT_LOOP="$1"
    ITER_START_TIME=$(date +%s)
    tui_render
}

tui_set_phase_info() {
    CURRENT_PHASE_INFO="$1"
    tui_render
}

tui_set_tokens() {
    CURRENT_TOKEN_COUNT="$1"
    # Don't render on every token update to reduce flicker; caller controls render
}

# ──────────────────────────────────────────────────────────────
# Activity log (scrolling message list)
# ──────────────────────────────────────────────────────────────
_activity() {
    local ts
    ts=$(date '+%H:%M:%S')
    ACTIVITY_LOG+=("${ts}  $1")
    # Keep bounded
    if [[ ${#ACTIVITY_LOG[@]} -gt 50 ]]; then
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────
# Public log functions (update TUI + write to file)
# ──────────────────────────────────────────────────────────────
log_iteration_header() {
    local loop_num="$1"
    local max_loops="$2"
    CURRENT_LOOP="$loop_num"
    CURRENT_MAX_LOOPS="$max_loops"
    ITER_START_TIME=$(date +%s)
    CURRENT_TOKEN_COUNT=0
    CURRENT_STATUS="RUNNING"
    CURRENT_SIGNAL=""
    _activity "Loop ${loop_num} started"
    tui_render; return 0
}

log_success() {
    _activity "OK  $1"
    tui_render; return 0
}

log_warning() {
    _activity "!!  $1"
    tui_render; return 0
}

log_error() {
    _activity "ERR $1"
    tui_render; return 0
}

log_info() {
    _activity "--- $1"
    tui_render; return 0
}

log_debug() {
    _activity "    $1"
    return 0
}

log_token_progress() {
    local current="$1"
    local limit="$2"
    CURRENT_TOKEN_COUNT="$current"
    CURRENT_TOKEN_LIMIT="$limit"
    tui_render; return 0
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

    CURRENT_SIGNAL="$signal"
    _activity "Loop ${loop_num} -> ${signal} (${tokens} tok, ${duration})"
    tui_render; return 0
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

    if [[ "$final_signal" == "ALL_PHASES_COMPLETE" ]]; then
        CURRENT_STATUS="DONE"
    else
        CURRENT_STATUS="ERROR"
    fi
    _activity "Finished: ${final_signal} after ${total_iterations} iterations"
    tui_render

    # Leave TUI up for a moment so user can see final state, then tear down
    sleep 2
    tui_cleanup

    # Print a plain-text summary after restoring the normal terminal
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
    for ((i = 0; i < hist_count; i++)); do
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
