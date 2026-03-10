#!/usr/bin/env bash
# log-manager.sh - TUI dashboard with real-time visibility into Tarvos runs
# Phase 3: Refactored to use tui-core.sh panels, live event tail, scroll/view toggle, key handlers.

# ──────────────────────────────────────────────────────────────
# Source shared TUI core library
# ──────────────────────────────────────────────────────────────
_LM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui-core.sh
source "${_LM_SCRIPT_DIR}/tui-core.sh"

# ──────────────────────────────────────────────────────────────
# Color aliases (map legacy names to tui-core.sh palette)
# ──────────────────────────────────────────────────────────────
RED="$TC_ERROR"
GREEN="$TC_SUCCESS"
YELLOW="$TC_WARNING"
BLUE="$TC_INFO"
MAGENTA="$TC_PURPLE"
CYAN="$TC_INFO"
WHITE="\033[1;37m"
BOLD="$TC_BOLD"
DIM="$TC_DIM"
RESET="$TC_RESET"
BG_DARK="$TC_PANEL_BG"
BG_HEADER="$TC_HEADER_BG"
BG_SUCCESS="\033[48;5;22m"
BG_WARN="\033[48;5;130m"
BG_ERR="\033[48;5;52m"

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
CURRENT_STATUS="IDLE"       # IDLE, RUNNING, CONTEXT_LIMIT, CONTINUATION, RECOVERY, DONE, ERROR
CURRENT_SESSION_NAME=""     # optional — set for header subtitle
RUN_START_TIME=0
ITER_START_TIME=0

# History of completed iterations (last 10)
declare -a HISTORY_LOOP=()
declare -a HISTORY_SIGNAL=()
declare -a HISTORY_TOKENS=()
declare -a HISTORY_DURATION=()
declare -a HISTORY_NOTE=()

# Activity log — array of formatted display lines (bounded to 500 entries)
declare -a ACTIVITY_LOG=()
MAX_ACTIVITY_STORED=500

# Phase 3: scroll and view mode state
LOG_SCROLL_OFFSET=0     # 0 = bottom/latest; positive = scrolled up N lines
LOG_VIEW_MODE="summary" # "summary" or "raw"

# Phase 3: event tail reader state
_LM_TAIL_PID=""         # PID of background tail reader subshell
_LM_TAIL_TMPFILE=""     # temp file that accumulates pending raw event lines
_LM_CURRENT_EVENTS_LOG="" # path to the current loop-NNN-events.jsonl

# ──────────────────────────────────────────────────────────────
# Logging init
# ──────────────────────────────────────────────────────────────
init_logging() {
    local base_dir="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    # If the base_dir looks like a session folder (.tarvos/sessions/<name>), use its logs/ directly.
    # Otherwise keep the legacy project-level path.
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
# TUI lifecycle
# ──────────────────────────────────────────────────────────────
tui_init() {
    local max_loops="$1"
    local token_limit="$2"
    CURRENT_MAX_LOOPS="$max_loops"
    CURRENT_TOKEN_LIMIT="$token_limit"
    RUN_START_TIME=$(date +%s)

    # Skip TUI when running without a terminal (e.g. detached/nohup mode)
    if [[ ! -t 1 ]]; then
        TUI_ENABLED=0
        return 0
    fi

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
    # Stop event tail reader if running
    _lm_tail_stop

    if [[ "$TUI_ENABLED" -eq 1 ]]; then
        TUI_ENABLED=0
        tput cnorm 2>/dev/null   # show cursor
        tput rmcup 2>/dev/null   # restore screen
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────
# Event tail reader — background process that watches the current
# loop-NNN-events.jsonl and appends new lines to _LM_TAIL_TMPFILE
# ──────────────────────────────────────────────────────────────

_lm_tail_start() {
    local events_log="$1"
    _lm_tail_stop  # stop any existing reader

    _LM_CURRENT_EVENTS_LOG="$events_log"
    _LM_TAIL_TMPFILE=$(mktemp)

    if [[ ! -f "$events_log" ]]; then
        return 0
    fi

    # Background tail: appends new lines to the tmp file
    (
        tail -f "$events_log" 2>/dev/null >> "$_LM_TAIL_TMPFILE"
    ) &
    _LM_TAIL_PID=$!
}

_lm_tail_stop() {
    if [[ -n "$_LM_TAIL_PID" ]] && kill -0 "$_LM_TAIL_PID" 2>/dev/null; then
        kill "$_LM_TAIL_PID" 2>/dev/null
        wait "$_LM_TAIL_PID" 2>/dev/null || true
    fi
    _LM_TAIL_PID=""
    if [[ -n "$_LM_TAIL_TMPFILE" ]] && [[ -f "$_LM_TAIL_TMPFILE" ]]; then
        rm -f "$_LM_TAIL_TMPFILE"
    fi
    _LM_TAIL_TMPFILE=""
}

# Drain pending lines from the tail tmpfile into ACTIVITY_LOG
# Returns 0 if new events were processed (triggers re-render), 1 if no new events
_lm_drain_events() {
    [[ -z "$_LM_TAIL_TMPFILE" ]] && return 1
    [[ ! -s "$_LM_TAIL_TMPFILE" ]] && return 1

    local new_events
    new_events=$(cat "$_LM_TAIL_TMPFILE" 2>/dev/null)
    # Clear the tmp file atomically (truncate) so we don't re-read
    > "$_LM_TAIL_TMPFILE"

    [[ -z "$new_events" ]] && return 1

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _lm_append_event_line "$line"
    done <<< "$new_events"

    return 0
}

# Parse a single events-jsonl line and append a formatted entry to ACTIVITY_LOG
_lm_append_event_line() {
    local line="$1"
    local event_type
    event_type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    local ts_raw
    ts_raw=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
    local ts_str="--:--:--"
    if [[ -n "$ts_raw" ]] && [[ "$ts_raw" =~ ^[0-9]+$ ]]; then
        ts_str=$(date -d "@${ts_raw}" '+%H:%M:%S' 2>/dev/null \
                 || date -r "$ts_raw" '+%H:%M:%S' 2>/dev/null \
                 || echo "--:--:--")
    fi

    local formatted=""
    case "$event_type" in
        tool_use)
            local tool input
            tool=$(printf '%s' "$line" | jq -r '.tool // "?"' 2>/dev/null)
            input=$(printf '%s' "$line" | jq -r '.input // ""' 2>/dev/null)
            # input may be a stringified JSON; show first 60 chars
            input="${input:0:60}"
            if [[ "$LOG_VIEW_MODE" == "summary" ]]; then
                formatted="${ts_str}  ${TC_ACCENT}▶ ${tool}:${TC_RESET} ${input}"
            fi
            # raw mode: skip tool events
            ;;
        tool_result)
            local output success
            output=$(printf '%s' "$line" | jq -r '.output // ""' 2>/dev/null)
            output="${output:0:60}"
            success=$(printf '%s' "$line" | jq -r '.success // "true"' 2>/dev/null)
            if [[ "$LOG_VIEW_MODE" == "summary" ]]; then
                if [[ "$success" == "true" ]]; then
                    formatted="${ts_str}  ${TC_SUCCESS}✓${TC_RESET} ${output}"
                else
                    formatted="${ts_str}  ${TC_ERROR}✗${TC_RESET} ${output}"
                fi
            fi
            # raw mode: skip tool result events
            ;;
        text)
            local content
            content=$(printf '%s' "$line" | jq -r '.content // ""' 2>/dev/null)
            content="${content:0:60}"
            if [[ "$LOG_VIEW_MODE" == "summary" ]]; then
                formatted="${ts_str}  ${TC_MUTED}· Claude:${TC_RESET} ${content}"
            else
                # raw mode: show text verbatim
                formatted="${ts_str}  ${content}"
            fi
            ;;
        signal)
            local value
            value=$(printf '%s' "$line" | jq -r '.value // ""' 2>/dev/null)
            if [[ "$LOG_VIEW_MODE" == "summary" ]]; then
                formatted="${ts_str}  ${TC_INFO}⚑ ${value}${TC_RESET}"
            else
                formatted="${ts_str}  ${TC_INFO}⚑ ${value}${TC_RESET}"
            fi
            ;;
        *)
            return 0
            ;;
    esac

    [[ -z "$formatted" ]] && return 0

    ACTIVITY_LOG+=("$formatted")
    # Keep bounded
    if [[ ${#ACTIVITY_LOG[@]} -gt $MAX_ACTIVITY_STORED ]]; then
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    fi
}

# ──────────────────────────────────────────────────────────────
# TUI rendering — full-screen run view using tui-core.sh panels
# ──────────────────────────────────────────────────────────────

# Move to row,col (1-based internal helper)
_mv() { tput cup "$(($1 - 1))" "$(($2 - 1))" 2>/dev/null; }

# Print a full-width line padded with spaces
_line() {
    local text="$1"
    printf "%-${TUI_COLS}s" "$text"
}

tui_render() {
    [[ "$TUI_ENABLED" -eq 1 ]] || return 0

    # Refresh terminal size
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_ROWS=$(tput lines 2>/dev/null || echo 24)
    TC_COLS=$TUI_COLS
    TC_ROWS=$TUI_ROWS

    local now
    now=$(date +%s)
    local elapsed=$(( now - RUN_START_TIME ))
    local elapsed_str
    elapsed_str=$(format_duration "$elapsed")
    local iter_elapsed=""
    if [[ "$ITER_START_TIME" -gt 0 ]]; then
        iter_elapsed=$(format_duration $(( now - ITER_START_TIME )))
    fi

    local w=$TUI_COLS
    local cur_row=0   # 0-indexed for tput cup

    # ── Header (2 rows) ──
    # Build subtitle: session name + status + loop info + context bar
    local status_icon status_color
    status_icon=$(tc_status_icon "$CURRENT_STATUS")
    status_color=$(tc_status_color "$CURRENT_STATUS")

    local loop_info="${CURRENT_LOOP}/${CURRENT_MAX_LOOPS}"
    local pct=0
    if [[ "$CURRENT_TOKEN_LIMIT" -gt 0 ]]; then
        pct=$(( CURRENT_TOKEN_COUNT * 100 / CURRENT_TOKEN_LIMIT ))
        [[ "$pct" -gt 100 ]] && pct=100
    fi
    local prog_bar
    prog_bar=$(tc_draw_progress "$pct" 16)

    local subtitle
    if [[ -n "$CURRENT_SESSION_NAME" ]]; then
        subtitle="${CURRENT_SESSION_NAME}  ${status_color}${status_icon} ${CURRENT_STATUS}${TC_RESET}  Loop ${loop_info}  ${prog_bar} ${pct}% context"
    else
        subtitle="${status_color}${status_icon} ${CURRENT_STATUS}${TC_RESET}  Loop ${loop_info}  ${prog_bar} ${pct}% context"
    fi

    tput cup 0 0 2>/dev/null
    tc_draw_header "$subtitle"
    cur_row=2

    # ── Blank row ──
    tput cup $cur_row 0 2>/dev/null; printf "%-${w}s" ""; cur_row=$(( cur_row + 1 ))

    # ── Status panel (3 rows: top+1 content+bottom) ──
    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_top "Status" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    local status_label
    case "$CURRENT_STATUS" in
        IDLE)           status_label="Idle" ;;
        RUNNING)        status_label="Agent running" ;;
        CONTEXT_LIMIT)  status_label="Context limit hit" ;;
        CONTINUATION)   status_label="Continuation session" ;;
        RECOVERY)       status_label="Recovery session" ;;
        DONE)           status_label="Complete" ;;
        ERROR)          status_label="Error" ;;
        *)              status_label="$CURRENT_STATUS" ;;
    esac

    local spinner_frame=""
    [[ "$CURRENT_STATUS" == "RUNNING" ]] && spinner_frame=" $(tc_spinner_frame $TC_RENDER_TICK)"

    local line1_plain="${status_color}${status_icon}${spinner_frame}${TC_RESET} ${status_label}"
    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_line "  ${line1_plain}" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    local elapsed_line="  ${TC_DIM}Elapsed:${TC_RESET} $(printf '%-12s' "$elapsed_str")  ${TC_DIM}Iteration:${TC_RESET} $(printf '%-12s' "${iter_elapsed:-—}")"
    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_line "$elapsed_line" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    if [[ -n "$CURRENT_PHASE_INFO" ]]; then
        local phase_line="  ${TC_DIM}Phase:${TC_RESET} ${CURRENT_PHASE_INFO}"
        tput cup $cur_row 0 2>/dev/null
        tc_draw_box_line "$phase_line" "$w" "$TC_NORMAL"
        cur_row=$(( cur_row + 1 ))
    fi

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_bottom "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    # ── Context Window panel (3 rows) ──
    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_top "Context Window" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    local ctx_bar
    ctx_bar=$(tc_draw_progress "$pct" 24)
    local ctx_line="  ${ctx_bar}   ${CURRENT_TOKEN_COUNT} / ${CURRENT_TOKEN_LIMIT} tokens"
    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_line "$ctx_line" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_bottom "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    # ── History panel ──
    local hist_count=${#HISTORY_LOOP[@]}
    # How many rows can we dedicate to history? Leave at least 8 for activity log panel.
    local remaining_for_history=$(( TUI_ROWS - cur_row - 8 - 2 ))
    [[ "$remaining_for_history" -lt 2 ]] && remaining_for_history=2
    [[ "$remaining_for_history" -gt 6 ]] && remaining_for_history=6

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_top "History" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    local hist_rows_shown=0
    local hist_start=0
    [[ "$hist_count" -gt "$remaining_for_history" ]] && hist_start=$(( hist_count - remaining_for_history ))

    local i
    for (( i=hist_start; i<hist_count && hist_rows_shown<remaining_for_history; i++ )); do
        local sig="${HISTORY_SIGNAL[$i]}"
        local sc="${TC_SUCCESS}"
        case "$sig" in
            PHASE_IN_PROGRESS) sc="${TC_WARNING}" ;;
            NO_SIGNAL*|ERROR*) sc="${TC_ERROR}" ;;
        esac
        local hline="  ${TC_MUTED}#${HISTORY_LOOP[$i]}${TC_RESET}  ${sc}$(printf '%-22s' "${HISTORY_SIGNAL[$i]}")${TC_RESET}  $(printf '%-8s' "${HISTORY_TOKENS[$i]}")  $(printf '%-8s' "${HISTORY_DURATION[$i]}")  ${TC_MUTED}${HISTORY_NOTE[$i]}${TC_RESET}"
        tput cup $cur_row 0 2>/dev/null
        tc_draw_box_line "$hline" "$w" "$TC_NORMAL"
        cur_row=$(( cur_row + 1 ))
        (( hist_rows_shown++ ))
    done

    # Fill empty history rows
    while (( hist_rows_shown < remaining_for_history )); do
        tput cup $cur_row 0 2>/dev/null
        tc_draw_box_line "" "$w" "$TC_NORMAL"
        cur_row=$(( cur_row + 1 ))
        (( hist_rows_shown++ ))
    done

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_bottom "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    # ── Activity Log panel — fills remaining space above footer ──
    # Footer takes 1 row; activity panel takes the rest
    local footer_row=$(( TUI_ROWS - 1 ))
    local act_panel_rows=$(( footer_row - cur_row - 1 ))  # -1 for panel bottom border
    [[ "$act_panel_rows" -lt 3 ]] && act_panel_rows=3

    # Panel title with view mode toggle hint
    local view_hint
    if [[ "$LOG_VIEW_MODE" == "raw" ]]; then
        view_hint="[v] summary mode"
    else
        view_hint="[v] toggle raw"
    fi

    # Build right-aligned title suffix
    local act_title="Activity Log"
    local hint_padded="$(printf '%s' "$view_hint")"
    local title_width=$(( w - ${#act_title} - ${#hint_padded} - 6 ))
    [[ "$title_width" -lt 1 ]] && title_width=1
    local act_panel_title="${act_title}$(printf '%*s' $title_width '')${hint_padded}"

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_top "$act_panel_title" "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    # Compute which slice of ACTIVITY_LOG to show
    local act_count=${#ACTIVITY_LOG[@]}
    local act_show=$(( act_panel_rows - 2 ))  # -2 for top+bottom borders (top already drawn)
    # Actually act_panel_rows is the inner content rows count, so:
    act_show=$(( act_panel_rows ))
    [[ "$act_show" -lt 1 ]] && act_show=1

    # Apply scroll offset
    # offset 0 = show latest; offset N = show N lines from bottom (older entries)
    local act_end=$(( act_count - LOG_SCROLL_OFFSET ))
    [[ "$act_end" -lt 0 ]] && act_end=0
    [[ "$act_end" -gt "$act_count" ]] && act_end=$act_count
    local act_start=$(( act_end - act_show ))
    [[ "$act_start" -lt 0 ]] && act_start=0

    local shown_count=$(( act_end - act_start ))
    local blank_before=$(( act_show - shown_count ))
    [[ "$blank_before" -lt 0 ]] && blank_before=0

    # Blank leading rows
    local j
    for (( j=0; j<blank_before; j++ )); do
        tput cup $cur_row 0 2>/dev/null
        tc_draw_box_line "" "$w" "$TC_NORMAL"
        cur_row=$(( cur_row + 1 ))
    done

    for (( i=act_start; i<act_end; i++ )); do
        tput cup $cur_row 0 2>/dev/null
        tc_draw_box_line "  ${ACTIVITY_LOG[$i]}" "$w" "$TC_NORMAL"
        cur_row=$(( cur_row + 1 ))
    done

    tput cup $cur_row 0 2>/dev/null
    tc_draw_box_bottom "$w" "$TC_NORMAL"
    cur_row=$(( cur_row + 1 ))

    # ── Footer ──
    if [[ "$LOG_VIEW_MODE" == "raw" ]]; then
        tc_draw_footer "↑↓" "Scroll log" "v" "Summary mode" "b" "Background" "q" "Back to list"
    else
        tc_draw_footer "↑↓" "Scroll log" "v" "Toggle raw" "b" "Background" "q" "Back to list"
    fi

    # Fill any remaining rows between activity bottom and footer
    while (( cur_row < footer_row )); do
        tput cup $cur_row 0 2>/dev/null
        printf "%-${w}s" ""
        cur_row=$(( cur_row + 1 ))
    done

    # Advance render tick for animation effects
    TC_RENDER_TICK=$(( TC_RENDER_TICK + 1 ))

    return 0
}

# ──────────────────────────────────────────────────────────────
# Phase 3: Key handler for interactive run view
# Called from tui_run_interactive or future tui-app.sh screen dispatch
# ──────────────────────────────────────────────────────────────

# Handler return codes (stored in _LM_KEY_ACTION):
_LM_KEY_ACTION=""   # "background", "quit", or "" (no special action)

tui_handle_key() {
    local key="$1"
    _LM_KEY_ACTION=""

    case "$key" in
        # Scroll up (older entries)
        $'\x1b[A'|"k")
            local max_offset=$(( ${#ACTIVITY_LOG[@]} ))
            LOG_SCROLL_OFFSET=$(( LOG_SCROLL_OFFSET + 1 ))
            [[ "$LOG_SCROLL_OFFSET" -gt "$max_offset" ]] && LOG_SCROLL_OFFSET=$max_offset
            ;;
        # Scroll down (newer entries)
        $'\x1b[B'|"j")
            LOG_SCROLL_OFFSET=$(( LOG_SCROLL_OFFSET - 1 ))
            [[ "$LOG_SCROLL_OFFSET" -lt 0 ]] && LOG_SCROLL_OFFSET=0
            ;;
        # Toggle view mode
        "v")
            if [[ "$LOG_VIEW_MODE" == "summary" ]]; then
                LOG_VIEW_MODE="raw"
            else
                LOG_VIEW_MODE="summary"
            fi
            # Rebuild activity log from events file for the new mode
            _lm_rebuild_activity_log
            ;;
        # Detach to background
        "b")
            _LM_KEY_ACTION="background"
            ;;
        # Back to list / quit
        "q")
            _LM_KEY_ACTION="quit"
            ;;
    esac
}

# Rebuild the ACTIVITY_LOG from the current events log file (used after view mode toggle)
_lm_rebuild_activity_log() {
    ACTIVITY_LOG=()
    local events_file="$_LM_CURRENT_EVENTS_LOG"
    [[ -z "$events_file" ]] && return 0
    [[ ! -f "$events_file" ]] && return 0

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _lm_append_event_line "$line"
    done < "$events_file"
}

# ──────────────────────────────────────────────────────────────
# Interactive run view loop — for use from tui-app.sh or direct attach
# Renders the run view and processes keypresses while the session is active.
# Exits when: key 'q' (return to list), key 'b' (background), or session done.
# Returns: 0 normally, 1 if background was requested
# ──────────────────────────────────────────────────────────────
tui_run_interactive() {
    local events_log="${1:-}"
    [[ -n "$events_log" ]] && _lm_tail_start "$events_log"

    # Put terminal in raw single-char read mode
    local old_stty
    old_stty=$(stty -g 2>/dev/null || true)
    stty -echo -icanon min 0 time 0 2>/dev/null || true

    while true; do
        # Drain new events from tail reader
        _lm_drain_events && {
            # New events arrived — auto-scroll to bottom if user hasn't scrolled up
            [[ "$LOG_SCROLL_OFFSET" -eq 0 ]] || true
        }

        tui_render

        # Non-blocking read with ~0.5s timeout
        local key=""
        if read -r -s -n1 -t 0.5 key 2>/dev/null; then
            # Handle escape sequences (arrow keys)
            if [[ "$key" == $'\x1b' ]]; then
                local seq=""
                read -r -s -n2 -t 0.1 seq 2>/dev/null || true
                key="${key}${seq}"
            fi
            tui_handle_key "$key"

            if [[ "$_LM_KEY_ACTION" == "quit" ]]; then
                break
            elif [[ "$_LM_KEY_ACTION" == "background" ]]; then
                stty "$old_stty" 2>/dev/null || true
                _lm_tail_stop
                return 1
            fi
        fi

        # Exit loop if session is done/error
        if [[ "$CURRENT_STATUS" == "DONE" ]] || [[ "$CURRENT_STATUS" == "ERROR" ]]; then
            # Give one final render, then wait for a keypress
            tui_render
            read -r -s -n1 2>/dev/null || true
            break
        fi
    done

    stty "$old_stty" 2>/dev/null || true
    _lm_tail_stop
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
    LOG_SCROLL_OFFSET=0   # reset scroll on new loop
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
# Activity log — legacy push interface (used by log_success etc.)
# These bypass the events-jsonl reader and write directly
# ──────────────────────────────────────────────────────────────
_activity() {
    local ts
    ts=$(date '+%H:%M:%S')
    local entry="${ts}  $1"
    ACTIVITY_LOG+=("$entry")
    # Keep bounded
    if [[ ${#ACTIVITY_LOG[@]} -gt $MAX_ACTIVITY_STORED ]]; then
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    fi
    return 0
}

# Start the event tail reader for loop N (called from run_iteration in tarvos.sh after log init)
tui_start_events_tail() {
    local loop_num="$1"
    local events_log
    events_log=$(get_events_log "$loop_num")
    _lm_tail_start "$events_log"
    _LM_CURRENT_EVENTS_LOG="$events_log"
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
    LOG_SCROLL_OFFSET=0  # reset scroll on new loop
    _activity "Loop ${loop_num} started"
    tui_render; return 0
}

log_success() {
    _activity "${TC_SUCCESS}✓${TC_RESET}  $1"
    tui_render; return 0
}

log_warning() {
    _activity "${TC_WARNING}!!${TC_RESET} $1"
    tui_render; return 0
}

log_error() {
    _activity "${TC_ERROR}✗${TC_RESET}  $1"
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

# ──────────────────────────────────────────────────────────────
# Completion overlay screen — shown when ALL_PHASES_COMPLETE
# Displays a full-screen panel with summary content streamed live.
# Args: $1 = session_name (for title and summary file path)
# ──────────────────────────────────────────────────────────────
tui_show_completion_overlay() {
    local session_name="${1:-}"
    [[ "$TUI_ENABLED" -eq 1 ]] || return 0

    local summary_file=""
    if [[ -n "$session_name" ]]; then
        summary_file=".tarvos/sessions/${session_name}/summary.md"
    fi

    local w=$TUI_COLS
    local panel_title=" ✓ PRD Complete"
    [[ -n "$session_name" ]] && panel_title=" ✓ PRD Complete — ${session_name}"

    # Put terminal in raw single-char read mode
    local old_stty
    old_stty=$(stty -g 2>/dev/null || true)
    stty -echo -icanon min 0 time 0 2>/dev/null || true

    local pager="${PAGER:-less}"
    local done_key=0

    while [[ "$done_key" -eq 0 ]]; do
        # Refresh terminal dimensions
        TUI_COLS=$(tput cols 2>/dev/null || echo 80)
        TUI_ROWS=$(tput lines 2>/dev/null || echo 24)
        w=$TUI_COLS

        tput clear 2>/dev/null

        # Header (2 rows)
        local now_str
        now_str=$(date '+%H:%M:%S')
        local header_right="  ${now_str}  "
        local header_title="  ${TC_BOLD}${TC_NORMAL}🦥 TARVOS${TC_RESET}"
        local header_sub="  ${TC_DIM}Autonomous AI Coding Orchestrator${TC_RESET}"
        _mv 1 1
        printf '%b' "${TC_HEADER_BG}"; _line "${header_title}"; printf '%b' "${TC_RESET}"
        _mv 1 $(( w - ${#header_right} + 1 ))
        printf '%b' "${TC_HEADER_BG}${TC_MUTED}${header_right}${TC_RESET}"
        _mv 2 1
        printf '%b' "${TC_HEADER_BG}"; _line "${header_sub}"; printf '%b' "${TC_RESET}"
        _mv 3 1; printf '\n'

        # Summary panel
        local panel_row=4
        local panel_height=$(( TUI_ROWS - panel_row - 2 ))
        [[ $panel_height -lt 5 ]] && panel_height=5

        _mv $panel_row 1
        tc_draw_box_top "$panel_title" "$w" "${TC_SUCCESS}"

        local summary_lines=()
        if [[ -n "$summary_file" ]] && [[ -f "$summary_file" ]]; then
            while IFS= read -r line; do
                summary_lines+=("  ${line}")
            done < "$summary_file"
        fi

        local inner_height=$(( panel_height - 2 ))
        local available=$(( inner_height - 4 ))  # reserve space for status lines

        # Show status / generating message
        local summary_count=${#summary_lines[@]}
        local generating_msg=""
        if [[ $summary_count -eq 0 ]]; then
            generating_msg="  ⠋ Generating summary..."
        else
            generating_msg="  Summary saved to .tarvos/sessions/${session_name}/summary.md"
        fi

        # Render content lines (first N lines of summary)
        local row_idx=0
        _mv $(( panel_row + 1 )) 1
        tc_draw_box_line "" "$w" "${TC_SUCCESS}"
        for (( row_idx=0; row_idx < available && row_idx < summary_count; row_idx++ )); do
            tc_draw_box_line "${summary_lines[$row_idx]}" "$w" "${TC_SUCCESS}"
        done
        # Fill remaining rows
        local remaining=$(( inner_height - summary_count - 2 ))
        [[ $remaining -lt 0 ]] && remaining=0
        local fill_idx
        for (( fill_idx=0; fill_idx < remaining; fill_idx++ )); do
            tc_draw_box_line "" "$w" "${TC_SUCCESS}"
        done
        tc_draw_box_line "" "$w" "${TC_SUCCESS}"
        tc_draw_box_line "  ${TC_DIM}${generating_msg}${TC_RESET}" "$w" "${TC_SUCCESS}"

        tc_draw_box_bottom "$w" "${TC_SUCCESS}"

        # Footer
        local footer_row=$(( TUI_ROWS - 1 ))
        _mv $footer_row 1
        local footer_line
        if [[ -n "$summary_file" ]] && [[ -f "$summary_file" ]]; then
            footer_line="  ${TC_ACCENT}[Enter]${TC_RESET} Back to list  ${TC_ACCENT}[s]${TC_RESET} Open summary.md  ${TC_ACCENT}[q]${TC_RESET} Quit"
        else
            footer_line="  ${TC_ACCENT}[Enter]${TC_RESET} Back to list  ${TC_ACCENT}[q]${TC_RESET} Quit"
        fi
        printf '%b' "${TC_PANEL_BG}"; _line "$footer_line"; printf '%b' "${TC_RESET}"

        # Read keypress (0.5s timeout for live update)
        local key=""
        if read -r -s -n1 -t 0.5 key 2>/dev/null; then
            case "$key" in
                $'\x0a'|$'\x0d'|'q')
                    done_key=1
                    ;;
                's')
                    if [[ -n "$summary_file" ]] && [[ -f "$summary_file" ]]; then
                        stty "$old_stty" 2>/dev/null || true
                        tput rmcup 2>/dev/null
                        "${pager}" "$summary_file"
                        tput smcup 2>/dev/null
                        tput civis 2>/dev/null
                        stty -echo -icanon min 0 time 0 2>/dev/null || true
                    fi
                    ;;
            esac
        fi
    done

    stty "$old_stty" 2>/dev/null || true
}

log_final_summary() {
    local total_iterations="$1"
    local final_signal="$2"
    local start_time="$3"
    local session_name="${4:-}"

    if [[ "$final_signal" == "ALL_PHASES_COMPLETE" ]]; then
        CURRENT_STATUS="DONE"
    else
        CURRENT_STATUS="ERROR"
    fi
    _activity "Finished: ${final_signal} after ${total_iterations} iterations"
    tui_render

    # For ALL_PHASES_COMPLETE: show completion overlay (waits for keypress)
    if [[ "$final_signal" == "ALL_PHASES_COMPLETE" ]] && [[ "$TUI_ENABLED" -eq 1 ]]; then
        tui_show_completion_overlay "$session_name"
        tui_cleanup
    else
        # Leave TUI up for a moment so user can see final state, then tear down
        sleep 2
        tui_cleanup
    fi

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
