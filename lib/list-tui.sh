#!/usr/bin/env bash
# list-tui.sh - Interactive session list TUI for Tarvos
# Reuses color/TUI patterns from log-manager.sh

# ──────────────────────────────────────────────────────────────
# Colors (duplicated here so list-tui.sh can be sourced independently)
# ──────────────────────────────────────────────────────────────
_L_RED='\033[0;31m'
_L_GREEN='\033[0;32m'
_L_YELLOW='\033[1;33m'
_L_BLUE='\033[0;34m'
_L_CYAN='\033[0;36m'
_L_WHITE='\033[1;37m'
_L_BOLD='\033[1m'
_L_DIM='\033[2m'
_L_RESET='\033[0m'
_L_BG_HEADER='\033[48;5;24m'
_L_BG_SEL='\033[48;5;237m'

# ──────────────────────────────────────────────────────────────
# Internal state
# ──────────────────────────────────────────────────────────────
_LIST_NAMES=()       # session names in display order
_LIST_ROWS=()        # rendered row strings (parallel to _LIST_NAMES)
_LIST_STATUSES=()    # status per session (parallel)
_LIST_SEL=0          # currently selected index (0-based)
_LIST_COLS=80
_LIST_ROWS_TERM=24
_LIST_TUI_ACTIVE=0

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

# Move cursor to row,col (1-based)
_lmv() { tput cup "$(($1 - 1))" "$(($2 - 1))" 2>/dev/null; }

# Pad/truncate string to exact width
_lpad() {
    local str="$1"
    local width="$2"
    printf "%-${width}s" "${str:0:${width}}"
}

# Format a last_activity ISO8601 timestamp as "Xm ago", "Xh ago", etc.
_format_activity() {
    local ts="$1"
    if [[ -z "$ts" ]] || [[ "$ts" == "null" ]]; then
        echo "—"
        return
    fi

    local ts_epoch now_epoch diff
    # macOS / BSD date
    if ts_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null); then
        :
    else
        # GNU date fallback
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "—"; return; }
    fi
    now_epoch=$(date +%s)
    diff=$(( now_epoch - ts_epoch ))

    if (( diff < 60 )); then
        echo "${diff}s ago"
    elif (( diff < 3600 )); then
        echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then
        echo "$(( diff / 3600 ))h ago"
    else
        echo "$(( diff / 86400 ))d ago"
    fi
}

# Status color
_status_color() {
    local status="$1"
    case "$status" in
        running)     echo "$_L_GREEN" ;;
        done)        echo "$_L_CYAN" ;;
        stopped)     echo "$_L_YELLOW" ;;
        initialized) echo "$_L_DIM" ;;
        failed)      echo "$_L_RED" ;;
        *)           echo "$_L_RESET" ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# Load session data from registry + session state files
# Populates _LIST_NAMES, _LIST_STATUSES, and raw data arrays
# ──────────────────────────────────────────────────────────────

# Per-session data (parallel arrays)
_LIST_BRANCHES=()
_LIST_ACTIVITIES=()

_list_load_sessions() {
    _LIST_NAMES=()
    _LIST_STATUSES=()
    _LIST_BRANCHES=()
    _LIST_ACTIVITIES=()

    if [[ ! -d "${SESSIONS_DIR:-.tarvos/sessions}" ]]; then
        return 0
    fi

    local state_file name status branch last_activity
    for state_file in "${SESSIONS_DIR:-.tarvos/sessions}"/*/state.json; do
        [[ -f "$state_file" ]] || continue
        name=$(jq -r '.name // ""' "$state_file" 2>/dev/null)
        [[ -z "$name" ]] && continue
        status=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null)
        branch=$(jq -r '.branch // ""' "$state_file" 2>/dev/null)
        last_activity=$(jq -r '.last_activity // ""' "$state_file" 2>/dev/null)

        _LIST_NAMES+=("$name")
        _LIST_STATUSES+=("$status")
        _LIST_BRANCHES+=("$branch")
        _LIST_ACTIVITIES+=("$last_activity")
    done
}

# ──────────────────────────────────────────────────────────────
# Render the full TUI screen
# ──────────────────────────────────────────────────────────────
_list_render() {
    _LIST_COLS=$(tput cols 2>/dev/null || echo 80)
    _LIST_ROWS_TERM=$(tput lines 2>/dev/null || echo 24)

    local w=$_LIST_COLS
    local count=${#_LIST_NAMES[@]}

    # Column widths
    local w_name=18
    local w_status=12
    local w_branch=28
    local w_activity=10
    # Separator spaces: 2 between each column
    local w_fixed=$(( w_name + w_status + w_branch + w_activity + 6 + 2 ))
    # Expand branch column if terminal is wide
    if (( w > w_fixed + 10 )); then
        w_branch=$(( w_branch + w - w_fixed - 10 ))
    fi

    local sep_w=$(( w_name + w_status + w_branch + w_activity + 6 ))
    [[ $sep_w -gt $(( w - 2 )) ]] && sep_w=$(( w - 2 ))

    # ── Header ──
    _lmv 1 1
    printf "${_L_BG_HEADER}${_L_WHITE}${_L_BOLD}%-${w}s${_L_RESET}" "  TARVOS SESSIONS"
    _lmv 2 1
    printf "${_L_DIM}  %s${_L_RESET}%-$(( w - sep_w - 2 ))s\n" "$(printf '─%.0s' $(seq 1 $sep_w))" ""

    # ── Column headers ──
    _lmv 3 1
    printf "  ${_L_BOLD}${_L_DIM}%-${w_name}s  %-${w_status}s  %-${w_branch}s  %-${w_activity}s${_L_RESET}" \
        "Name" "Status" "Branch" "Activity"
    printf "%-$(( w - w_name - w_status - w_branch - w_activity - 6 - 2 ))s" ""

    _lmv 4 1
    printf "  ${_L_DIM}%s${_L_RESET}%-$(( w - sep_w - 2 ))s\n" "$(printf '─%.0s' $(seq 1 $sep_w))" ""

    # ── Session rows ──
    local row=5
    local i
    for (( i = 0; i < count; i++ )); do
        local name="${_LIST_NAMES[$i]}"
        local status="${_LIST_STATUSES[$i]}"
        local branch="${_LIST_BRANCHES[$i]}"
        local activity
        activity=$(_format_activity "${_LIST_ACTIVITIES[$i]}")

        local sc
        sc=$(_status_color "$status")

        # Truncate branch display
        if [[ -z "$branch" ]]; then
            branch="(no branch yet)"
        fi

        local cursor="  "
        local bg=""
        local end_bg=""
        if (( i == _LIST_SEL )); then
            cursor="${_L_BOLD}▶ ${_L_RESET}"
            bg="${_L_BG_SEL}"
            end_bg="${_L_RESET}"
        fi

        _lmv $row 1
        printf "${bg}${cursor}${_L_BOLD}%-${w_name}s${_L_RESET}${bg}  ${sc}%-${w_status}s${_L_RESET}${bg}  ${_L_DIM}%-${w_branch}s${_L_RESET}${bg}  %-${w_activity}s${end_bg}" \
            "${name:0:$w_name}" \
            "${status:0:$w_status}" \
            "${branch:0:$w_branch}" \
            "${activity:0:$w_activity}"
        # Fill remainder of line to clear any leftover chars
        printf "%-$(( w - w_name - w_status - w_branch - w_activity - 6 - 2 ))s${_L_RESET}" ""

        (( row++ ))
        (( row > _LIST_ROWS_TERM - 2 )) && break
    done

    # ── Empty state ──
    if (( count == 0 )); then
        _lmv $row 1
        printf "  ${_L_DIM}No sessions found. Run \`tarvos init <prd> --name <name>\` to create one.${_L_RESET}%-$(( w - 70 ))s" ""
        (( row++ ))
    fi

    # ── Fill blank rows ──
    while (( row < _LIST_ROWS_TERM - 1 )); do
        _lmv $row 1
        printf "%-${w}s" ""
        (( row++ ))
    done

    # ── Footer ──
    _lmv $(( _LIST_ROWS_TERM - 1 )) 1
    printf "${_L_DIM}  %s${_L_RESET}%-$(( w - sep_w - 2 ))s" "$(printf '─%.0s' $(seq 1 $sep_w))" ""
    _lmv $(_LIST_ROWS_TERM) 1
    printf "${_L_DIM}  [↑↓] Navigate  [Enter] Actions  [r] Refresh  [q] Quit${_L_RESET}%-$(( w - 54 ))s" ""
}

# ──────────────────────────────────────────────────────────────
# Actions menu (context-aware)
# ──────────────────────────────────────────────────────────────

# Returns available action labels for a given status
_list_actions_for_status() {
    local status="$1"
    case "$status" in
        running)     echo "Attach Stop" ;;
        stopped)     echo "Resume Reject" ;;
        done)        echo "Accept Reject" ;;
        initialized) echo "Start Start\ \(bg\) Reject" ;;
        failed)      echo "Reject" ;;
        *)           echo "Reject" ;;
    esac
}

# Show an inline action menu at the bottom of the screen.
# Returns the selected action string, or empty string if cancelled.
_list_show_actions() {
    local name="$1"
    local status="$2"

    local -a actions=()
    case "$status" in
        running)     actions=("Attach" "Stop") ;;
        stopped)     actions=("Resume" "Reject") ;;
        done)        actions=("Accept" "Reject") ;;
        initialized) actions=("Start" "Start (bg)" "Reject") ;;
        failed)      actions=("Reject") ;;
        *)           actions=("Reject") ;;
    esac

    local sel=0
    local count=${#actions[@]}
    local w=$_LIST_COLS

    while true; do
        # Render action bar at bottom 3 lines
        _lmv $(( _LIST_ROWS_TERM - 2 )) 1
        printf "${_L_BOLD}  Actions for '${name}' [${status}]:${_L_RESET}%-$(( w - 30 - ${#name} - ${#status} ))s" ""

        _lmv $(( _LIST_ROWS_TERM - 1 )) 1
        local line="  "
        local i
        for (( i = 0; i < count; i++ )); do
            if (( i == sel )); then
                line+="${_L_BOLD}${_L_BG_SEL}[ ${actions[$i]} ]${_L_RESET}  "
            else
                line+="${_L_DIM}[ ${actions[$i]} ]${_L_RESET}  "
            fi
        done
        printf "%s%-$(( w ))s" "$line" ""

        _lmv $(_LIST_ROWS_TERM) 1
        printf "${_L_DIM}  [←→] Select action  [Enter] Confirm  [Esc/q] Cancel${_L_RESET}%-$(( w - 53 ))s" ""

        # Read single key
        local key
        IFS= read -r -s -n1 key 2>/dev/null || key=""

        case "$key" in
            $'\x1b')
                # Escape or arrow sequence
                local seq=""
                IFS= read -r -s -n1 -t 0.1 seq 2>/dev/null || true
                if [[ "$seq" == "[" ]]; then
                    local arrow=""
                    IFS= read -r -s -n1 -t 0.1 arrow 2>/dev/null || true
                    case "$arrow" in
                        C) (( sel < count - 1 )) && (( sel++ )) ;;  # right
                        D) (( sel > 0 )) && (( sel-- )) ;;          # left
                    esac
                else
                    # Plain Escape — cancel
                    echo ""
                    return 0
                fi
                ;;
            "")
                # Enter key
                echo "${actions[$sel]}"
                return 0
                ;;
            q|Q)
                echo ""
                return 0
                ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────────
# Execute an action
# ──────────────────────────────────────────────────────────────
_list_execute_action() {
    local name="$1"
    local action="$2"
    local tarvos_script="${3:-tarvos}"

    # Tear down TUI before running subcommands that print to terminal
    _list_tui_stop

    case "$action" in
        "Attach")
            "$tarvos_script" attach "$name"
            ;;
        "Stop")
            "$tarvos_script" stop "$name"
            ;;
        "Resume")
            "$tarvos_script" begin "$name" --continue
            ;;
        "Start")
            "$tarvos_script" begin "$name"
            ;;
        "Start (bg)")
            "$tarvos_script" begin "$name" --bg
            ;;
        "Accept")
            "$tarvos_script" accept "$name"
            ;;
        "Reject")
            "$tarvos_script" reject "$name"
            ;;
        "")
            # Cancelled — re-enter TUI
            _list_tui_start
            return 0
            ;;
    esac

    # After action completes, offer to return to list
    echo ""
    echo "Press any key to return to session list, or q to quit."
    local key
    IFS= read -r -s -n1 key 2>/dev/null || key="q"
    if [[ "$key" != "q" ]] && [[ "$key" != "Q" ]]; then
        _list_load_sessions
        _list_tui_start
    fi
}

# ──────────────────────────────────────────────────────────────
# TUI lifecycle
# ──────────────────────────────────────────────────────────────
_list_tui_start() {
    _LIST_TUI_ACTIVE=1
    tput smcup 2>/dev/null   # alternate screen
    tput civis 2>/dev/null   # hide cursor
    tput clear 2>/dev/null
    _list_render
}

_list_tui_stop() {
    if (( _LIST_TUI_ACTIVE )); then
        _LIST_TUI_ACTIVE=0
        tput cnorm 2>/dev/null   # show cursor
        tput rmcup 2>/dev/null   # restore screen
    fi
}

# ──────────────────────────────────────────────────────────────
# Main entry point: run the list TUI
# Args: $1 = tarvos_script path (for executing actions)
# ──────────────────────────────────────────────────────────────
list_tui_run() {
    local tarvos_script="${1:-tarvos}"

    if ! command -v jq &>/dev/null; then
        echo "tarvos list: jq is required but not installed." >&2
        return 1
    fi

    if [[ ! -t 1 ]]; then
        # Non-interactive: fall back to plain text listing
        _list_load_sessions
        local count=${#_LIST_NAMES[@]}
        if (( count == 0 )); then
            echo "No sessions found."
            return 0
        fi
        printf "%-20s  %-12s  %-30s  %s\n" "Name" "Status" "Branch" "Activity"
        printf "%s\n" "$(printf '─%.0s' $(seq 1 80))"
        local i
        for (( i = 0; i < count; i++ )); do
            local act
            act=$(_format_activity "${_LIST_ACTIVITIES[$i]}")
            local br="${_LIST_BRANCHES[$i]}"
            [[ -z "$br" ]] && br="(no branch)"
            printf "%-20s  %-12s  %-30s  %s\n" \
                "${_LIST_NAMES[$i]}" "${_LIST_STATUSES[$i]}" "$br" "$act"
        done
        return 0
    fi

    _list_load_sessions

    # Set up cleanup trap
    trap '_list_tui_stop; exit 0' INT TERM EXIT

    _list_tui_start

    local count=${#_LIST_NAMES[@]}

    while true; do
        # Refresh size
        _LIST_COLS=$(tput cols 2>/dev/null || echo 80)
        _LIST_ROWS_TERM=$(tput lines 2>/dev/null || echo 24)

        # Read a key (timeout so we can refresh periodically)
        local key=""
        IFS= read -r -s -n1 -t 5 key 2>/dev/null || true

        # Periodic refresh (on timeout key is empty)
        if [[ -z "$key" ]]; then
            _list_load_sessions
            count=${#_LIST_NAMES[@]}
            # Keep selection in bounds
            (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
            _list_render
            continue
        fi

        case "$key" in
            q|Q)
                break
                ;;
            r|R)
                _list_load_sessions
                count=${#_LIST_NAMES[@]}
                (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                _list_render
                ;;
            $'\x1b')
                # Arrow key escape sequence
                local seq="" arrow=""
                IFS= read -r -s -n1 -t 0.1 seq 2>/dev/null || true
                if [[ "$seq" == "[" ]]; then
                    IFS= read -r -s -n1 -t 0.1 arrow 2>/dev/null || true
                    case "$arrow" in
                        A)  # Up
                            (( _LIST_SEL > 0 )) && (( _LIST_SEL-- ))
                            _list_render
                            ;;
                        B)  # Down
                            (( count > 0 && _LIST_SEL < count - 1 )) && (( _LIST_SEL++ ))
                            _list_render
                            ;;
                    esac
                fi
                ;;
            "")
                # Enter key
                if (( count > 0 )); then
                    local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                    local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"

                    local action
                    action=$(_list_show_actions "$sel_name" "$sel_status")

                    if [[ -n "$action" ]]; then
                        _list_execute_action "$sel_name" "$action" "$tarvos_script"
                        # Reload after action
                        _list_load_sessions
                        count=${#_LIST_NAMES[@]}
                        (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                    else
                        # Cancelled — redraw
                        _list_render
                    fi
                fi
                ;;
        esac
    done

    _list_tui_stop
}
