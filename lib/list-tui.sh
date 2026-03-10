#!/usr/bin/env bash
# list-tui.sh — Session list TUI for Tarvos
# Rebuilt from scratch using tui-core.sh primitives.
# Provides a polished, full-screen session browser with action overlay,
# animated spinners, auto-refresh, and all key bindings from the PRD.

# Source tui-core.sh (find it relative to this file)
_LIST_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui-core.sh
source "${_LIST_TUI_DIR}/tui-core.sh"

# ──────────────────────────────────────────────────────────────
# Internal state
# ──────────────────────────────────────────────────────────────
_LIST_NAMES=()        # session names in display order
_LIST_STATUSES=()     # status per session (parallel)
_LIST_BRANCHES=()     # branch per session (parallel)
_LIST_ACTIVITIES=()   # last_activity ISO8601 per session (parallel)
_LIST_SEL=0           # currently selected index (0-based)
_LIST_TUI_ACTIVE=0    # 1 when alternate screen is active
_LIST_SPIN_IDX=()     # spinner frame index per session (for animated running indicator)
_LIST_RENDER_TICK=0   # global render tick counter

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

# Format a last_activity ISO8601 timestamp as "Xm ago", "Xh ago", etc.
_format_activity() {
    local ts="$1"
    if [[ -z "$ts" ]] || [[ "$ts" == "null" ]] || [[ "$ts" == "" ]]; then
        printf '—'
        return
    fi

    local ts_epoch now_epoch diff
    # Try macOS/BSD date first, then GNU date (handles %z timezone correctly)
    if ts_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null); then
        :
    elif ts_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$ts" +%s 2>/dev/null); then
        :
    else
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null) || { printf '—'; return; }
    fi
    now_epoch=$(date +%s)
    diff=$(( now_epoch - ts_epoch ))

    if (( diff < 60 )); then
        printf '%ds ago' "$diff"
    elif (( diff < 3600 )); then
        printf '%dm ago' "$(( diff / 60 ))"
    elif (( diff < 86400 )); then
        printf '%dh ago' "$(( diff / 3600 ))"
    else
        printf '%dd ago' "$(( diff / 86400 ))"
    fi
}

# ──────────────────────────────────────────────────────────────
# Load session data from state files
# Populates _LIST_NAMES, _LIST_STATUSES, _LIST_BRANCHES, _LIST_ACTIVITIES
# ──────────────────────────────────────────────────────────────
_list_load_sessions() {
    local prev_count=${#_LIST_NAMES[@]}

    _LIST_NAMES=()
    _LIST_STATUSES=()
    _LIST_BRANCHES=()
    _LIST_ACTIVITIES=()

    local sessions_dir="${SESSIONS_DIR:-.tarvos/sessions}"
    if [[ ! -d "$sessions_dir" ]]; then
        return 0
    fi

    local state_file name status branch last_activity
    for state_file in "${sessions_dir}"/*/state.json; do
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

    # Re-initialize spinner indices if session count changed
    local new_count=${#_LIST_NAMES[@]}
    if (( new_count != prev_count )); then
        _LIST_SPIN_IDX=()
        local i
        for (( i=0; i<new_count; i++ )); do
            _LIST_SPIN_IDX+=( $(( RANDOM % 10 )) )
        done
    fi
}

# ──────────────────────────────────────────────────────────────
# Render the full TUI screen
# ──────────────────────────────────────────────────────────────
_list_render() {
    _tc_update_dimensions
    local w="$TC_COLS"
    local h="$TC_ROWS"
    local count=${#_LIST_NAMES[@]}

    # Advance render tick + spinner indices for running sessions
    (( _LIST_RENDER_TICK++ )) || true
    local i
    for (( i=0; i<count; i++ )); do
        if [[ "${_LIST_STATUSES[$i]}" == "running" ]]; then
            _LIST_SPIN_IDX[$i]=$(( (_LIST_SPIN_IDX[$i] + 1) % 10 ))
        fi
    done

    # ── Header (rows 0-1) ──
    tc_draw_header

    # ── Sessions panel ──
    # Panel starts at row 3, leaves 1 row gap after header
    local panel_top=3
    # Height: terminal height minus header(2) minus gap(1) minus footer(1)
    local panel_height=$(( h - panel_top - 1 ))
    [[ $panel_height -lt 4 ]] && panel_height=4
    local panel_width=$(( w ))

    # Build sessions panel title with count
    local panel_title
    if (( count == 1 )); then
        panel_title="Sessions ── 1 session"
    else
        panel_title="Sessions ── ${count} sessions"
    fi

    # Top border
    tput cup "$panel_top" 0 2>/dev/null
    tc_draw_box_top "$panel_title" "$panel_width" "$TC_MUTED"

    # Column width budget (inside panel, subtract 2 for borders, 2 for cursor)
    local inner=$(( panel_width - 2 ))
    # Fixed column widths
    local w_cursor=3   # "▶  " or "   "
    local w_icon=2     # icon + space
    local w_name=18
    local w_status=12
    local w_activity=8
    # Branch gets the remainder
    local w_branch=$(( inner - w_cursor - w_icon - w_name - w_status - w_activity - 4 ))
    [[ $w_branch -lt 10 ]] && w_branch=10

    # How many session rows fit
    local max_rows=$(( panel_height - 2 ))  # subtract top+bottom borders
    [[ $max_rows -lt 1 ]] && max_rows=1

    # Draw rows
    local row=$(( panel_top + 1 ))
    local drawn=0

    if (( count == 0 )); then
        # Empty state
        tput cup "$row" 0 2>/dev/null
        local empty_msg="  No sessions found. Run \`tarvos init <prd> --name <name>\` to create one."
        local empty_pad=$(( inner - ${#empty_msg} ))
        [[ $empty_pad -lt 0 ]] && empty_pad=0
        printf '%b' "${TC_MUTED}│${TC_RESET}${TC_SUBTLE}${empty_msg}$(printf '%*s' "$empty_pad" '')${TC_MUTED}│${TC_RESET}\n"
        (( drawn++ ))
    else
        for (( i=0; i<count && drawn<max_rows; i++ )); do
            local name="${_LIST_NAMES[$i]}"
            local status="${_LIST_STATUSES[$i]}"
            local branch="${_LIST_BRANCHES[$i]}"
            local activity
            activity=$(_format_activity "${_LIST_ACTIVITIES[$i]}")

            # Selection indicator
            local is_sel=0
            (( i == _LIST_SEL )) && is_sel=1

            # Build cursor + icon
            local cursor_str icon_str
            if (( is_sel )); then
                cursor_str="${TC_ACCENT}${TC_BOLD}▶ ${TC_RESET}"
            else
                cursor_str="   "
            fi

            local icon color
            icon=$(tc_status_icon "$status")
            color=$(tc_status_color "$status")

            # Animate running sessions: spinner replaces icon
            if [[ "$status" == "running" ]]; then
                local spin_idx=${_LIST_SPIN_IDX[$i]:-0}
                icon=$(tc_spinner_frame "$spin_idx")
                # Pulse color
                if (( is_sel )); then
                    color=$(tc_pulse_color "$_LIST_RENDER_TICK")
                fi
            fi

            icon_str="${color}${icon}${TC_RESET}"

            # Truncate fields
            local name_disp branch_disp status_disp activity_disp
            name_disp="${name:0:$w_name}"
            printf -v name_disp "%-${w_name}s" "$name_disp"

            [[ -z "$branch" ]] && branch="—"
            branch_disp="${branch:0:$w_branch}"
            printf -v branch_disp "%-${w_branch}s" "$branch_disp"

            status_disp="${status:0:$w_status}"
            printf -v status_disp "%-${w_status}s" "$status_disp"

            activity_disp="${activity:0:$w_activity}"
            printf -v activity_disp "%-${w_activity}s" "$activity_disp"

            # Row background for selected
            local row_bg row_end
            if (( is_sel )); then
                row_bg="${TC_SEL_BG}"
                row_end="${TC_RESET}"
            else
                row_bg=""
                row_end=""
            fi

            tput cup "$row" 0 2>/dev/null
            # Build the content inside the box borders
            local content="${row_bg}${cursor_str}${icon_str}${row_bg} ${TC_BOLD}${name_disp}${TC_RESET}${row_bg}  ${color}${status_disp}${TC_RESET}${row_bg}  ${TC_MUTED}${branch_disp}${TC_RESET}${row_bg}  ${TC_SUBTLE}${activity_disp}${row_end}"

            # Measure plain length for padding
            local plain_content="${cursor_str:0:3}  ${name_disp}  ${status_disp}  ${branch_disp}  ${activity_disp}"
            local content_len=${#plain_content}
            local pad=$(( inner - content_len ))
            [[ $pad -lt 0 ]] && pad=0
            local padding
            padding=$(printf '%*s' "$pad" '')

            printf '%b' "${TC_MUTED}│${TC_RESET}${content}${row_bg}${padding}${row_end}${TC_MUTED}│${TC_RESET}\n"

            (( drawn++ ))
            (( row++ ))
        done
    fi

    # Fill remaining rows in panel
    while (( drawn < max_rows )); do
        tput cup "$row" 0 2>/dev/null
        printf '%b' "${TC_MUTED}│${TC_RESET}$(printf '%*s' "$inner" '')${TC_MUTED}│${TC_RESET}\n"
        (( drawn++ ))
        (( row++ ))
    done

    # Bottom border
    tput cup "$row" 0 2>/dev/null
    tc_draw_box_bottom "$panel_width" "$TC_MUTED"

    # ── Footer ──
    tc_draw_footer \
        "↑↓" "Navigate" \
        "Enter" "Open/Actions" \
        "s" "Start" \
        "a" "Accept" \
        "r" "Reject" \
        "n" "New" \
        "R" "Refresh" \
        "q" "Quit"
}

# ──────────────────────────────────────────────────────────────
# Action overlay (centered rounded-border panel)
# Returns the selected action string, or empty string if cancelled.
# ──────────────────────────────────────────────────────────────
_list_show_overlay() {
    local name="$1"
    local status="$2"

    # Determine available actions based on status
    local -a actions=()
    case "$status" in
        running)     actions=("Attach" "Stop") ;;
        stopped)     actions=("Resume" "Reject") ;;
        done)        actions=("Accept" "Reject" "View Summary") ;;
        initialized) actions=("Start" "Reject") ;;
        failed)      actions=("Reject") ;;
        *)           actions=("Reject") ;;
    esac

    local count=${#actions[@]}
    local sel=0

    # Overlay dimensions
    local ov_width=30
    local ov_height=$(( count + 4 ))  # title + blank + actions + blank + bottom
    local ov_row=$(( (TC_ROWS - ov_height) / 2 ))
    local ov_col=$(( (TC_COLS - ov_width) / 2 ))
    [[ $ov_row -lt 3 ]] && ov_row=3
    [[ $ov_col -lt 0 ]] && ov_col=0

    while true; do
        # Draw overlay panel
        tput cup "$ov_row" "$ov_col" 2>/dev/null
        tc_draw_box_top "Actions" "$ov_width" "$TC_ACCENT"

        # Blank line
        tput cup $(( ov_row + 1 )) "$ov_col" 2>/dev/null
        tc_draw_box_line "" "$ov_width" "$TC_ACCENT"

        # Action items
        local i
        for (( i=0; i<count; i++ )); do
            tput cup $(( ov_row + 2 + i )) "$ov_col" 2>/dev/null
            local action_line
            if (( i == sel )); then
                action_line="${TC_ACCENT}${TC_BOLD}  ▶  ${actions[$i]}${TC_RESET}"
            else
                action_line="${TC_SUBTLE}     ${actions[$i]}${TC_RESET}"
            fi
            tc_draw_box_line "$action_line" "$ov_width" "$TC_ACCENT"
        done

        # Blank line
        tput cup $(( ov_row + 2 + count )) "$ov_col" 2>/dev/null
        tc_draw_box_line "" "$ov_width" "$TC_ACCENT"

        # Bottom border
        tput cup $(( ov_row + 3 + count )) "$ov_col" 2>/dev/null
        tc_draw_box_bottom "$ov_width" "$TC_ACCENT"

        # Hint below overlay
        tput cup $(( ov_row + 4 + count )) $(( ov_col + 5 )) 2>/dev/null
        printf '%b' "${TC_MUTED}[Esc] Cancel${TC_RESET}"

        # Read key
        local key=""
        IFS= read -r -s -n1 key 2>/dev/null || key=""

        case "$key" in
            $'\x1b')
                local seq=""
                IFS= read -r -s -n1 -t 0.1 seq 2>/dev/null || true
                if [[ "$seq" == "[" ]]; then
                    local arrow=""
                    IFS= read -r -s -n1 -t 0.1 arrow 2>/dev/null || true
                    case "$arrow" in
                        A|D)  # Up / Left
                            (( sel > 0 )) && (( sel-- ))
                            ;;
                        B|C)  # Down / Right
                            (( sel < count - 1 )) && (( sel++ ))
                            ;;
                    esac
                else
                    # Plain Escape — cancel (no re-render bug)
                    printf ''
                    return 0
                fi
                ;;
            "")
                # Enter
                printf '%s' "${actions[$sel]}"
                return 0
                ;;
            j)
                (( sel < count - 1 )) && (( sel++ ))
                ;;
            k)
                (( sel > 0 )) && (( sel-- ))
                ;;
            q|Q)
                # Cancel
                printf ''
                return 0
                ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────────
# Execute an action for a session
# ──────────────────────────────────────────────────────────────
_list_execute_action() {
    local name="$1"
    local action="$2"
    local tarvos_script="${3:-tarvos}"

    [[ -z "$action" ]] && return 0  # Cancelled

    # Properly tear down TUI before running subcommands
    _list_tui_stop

    case "$action" in
        "Attach")
            "$tarvos_script" attach "$name"
            ;;
        "Stop")
            "$tarvos_script" stop "$name"
            ;;
        "Resume")
            "$tarvos_script" continue "$name"
            ;;
        "Start")
            "$tarvos_script" begin "$name"
            ;;
        "Accept")
            "$tarvos_script" accept "$name"
            ;;
        "Reject")
            "$tarvos_script" reject "$name"
            ;;
        "View Summary")
            local summary_file
            summary_file="${SESSIONS_DIR:-.tarvos/sessions}/${name}/summary.md"
            if [[ -f "$summary_file" ]]; then
                "${PAGER:-less}" "$summary_file"
            else
                echo "No summary available for session '${name}'."
                sleep 2
            fi
            ;;
    esac

    # After action, pause briefly then re-enter TUI (Attach takes over the terminal, skip)
    if [[ "$action" != "Attach" ]]; then
        echo ""
        printf '%b' "${TC_MUTED}Press any key to return to session list, or q to quit.${TC_RESET}\n"
        local key=""
        IFS= read -r -s -n1 key 2>/dev/null || key="q"
        if [[ "$key" == "q" ]] || [[ "$key" == "Q" ]]; then
            return 1  # signal caller to quit
        fi
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────
# Inline new-session prompt
# Prompts for session name + PRD path, then calls tarvos init
# ──────────────────────────────────────────────────────────────
_list_new_session_prompt() {
    local tarvos_script="$1"

    _list_tui_stop

    echo ""
    printf '%b' "${TC_ACCENT}${TC_BOLD}New Session${TC_RESET}\n"
    printf '%b' "${TC_MUTED}──────────────────────────────${TC_RESET}\n"

    # Restore cursor for input
    tput cnorm 2>/dev/null

    local sess_name prd_path
    printf '%b' "${TC_NORMAL}Session name: ${TC_RESET}"
    IFS= read -r sess_name
    printf '%b' "${TC_NORMAL}PRD path:     ${TC_RESET}"
    IFS= read -r prd_path

    if [[ -n "$sess_name" ]] && [[ -n "$prd_path" ]]; then
        echo ""
        "$tarvos_script" init "$prd_path" --name "$sess_name"
    else
        printf '%b' "${TC_WARNING}Cancelled.${TC_RESET}\n"
    fi

    echo ""
    printf '%b' "${TC_MUTED}Press any key to return to session list...${TC_RESET}\n"
    IFS= read -r -s -n1 _ 2>/dev/null || true

    return 0
}

# ──────────────────────────────────────────────────────────────
# TUI lifecycle
# ──────────────────────────────────────────────────────────────
_list_tui_start() {
    _LIST_TUI_ACTIVE=1
    tc_screen_init
    TC_RENDER_CALLBACK="_list_render"
    _list_render
}

_list_tui_stop() {
    if (( _LIST_TUI_ACTIVE )); then
        _LIST_TUI_ACTIVE=0
        TC_RENDER_CALLBACK=""
        tc_screen_cleanup
    fi
}

# ──────────────────────────────────────────────────────────────
# Main entry point: run the list TUI
# Args: $1 = tarvos_script path (default: "tarvos")
# ──────────────────────────────────────────────────────────────
list_tui_run() {
    local tarvos_script="${1:-tarvos}"

    if ! command -v jq &>/dev/null; then
        echo "tarvos tui: jq is required but not installed." >&2
        return 1
    fi

    # Non-interactive fallback (plain text listing)
    if [[ ! -t 1 ]]; then
        _list_load_sessions
        local count=${#_LIST_NAMES[@]}
        if (( count == 0 )); then
            echo "No sessions found."
            return 0
        fi
        printf "%-20s  %-12s  %-30s  %s\n" "Name" "Status" "Branch" "Activity"
        printf '%s\n' "$(printf '─%.0s' $(seq 1 80))"
        local i
        for (( i=0; i<count; i++ )); do
            local act br
            act=$(_format_activity "${_LIST_ACTIVITIES[$i]}")
            br="${_LIST_BRANCHES[$i]}"
            [[ -z "$br" ]] && br="(no branch)"
            printf "%-20s  %-12s  %-30s  %s\n" \
                "${_LIST_NAMES[$i]}" "${_LIST_STATUSES[$i]}" "$br" "$act"
        done
        return 0
    fi

    _list_load_sessions

    # Ensure selection is in bounds
    local count=${#_LIST_NAMES[@]}
    (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))

    # Cleanup trap — fixes nested smcup issue; runs on INT/TERM/EXIT
    trap '_list_tui_stop; exit 0' INT TERM EXIT

    _list_tui_start

    while true; do
        count=${#_LIST_NAMES[@]}
        (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))

        # Non-blocking read (3s timeout for auto-refresh and spinner animation)
        local key=""
        IFS= read -r -s -n1 -t 3 key 2>/dev/null || true

        if [[ -z "$key" ]]; then
            # Timeout: auto-refresh + re-render
            _list_load_sessions
            count=${#_LIST_NAMES[@]}
            (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
            _list_render
            continue
        fi

        case "$key" in
            q|Q)
                break
                ;;

            R)
                # Force refresh
                _list_load_sessions
                count=${#_LIST_NAMES[@]}
                (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                _list_render
                ;;

            k)
                # Move up
                (( _LIST_SEL > 0 )) && (( _LIST_SEL-- ))
                _list_render
                ;;

            j)
                # Move down
                (( count > 0 && _LIST_SEL < count - 1 )) && (( _LIST_SEL++ ))
                _list_render
                ;;

            s)
                # Start selected initialized session
                if (( count > 0 )); then
                    local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                    local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"
                    if [[ "$sel_status" == "initialized" ]]; then
                        _list_execute_action "$sel_name" "Start" "$tarvos_script" || break
                        _list_load_sessions
                        _list_tui_start
                    fi
                fi
                ;;

            a)
                # Accept selected done session
                if (( count > 0 )); then
                    local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                    local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"
                    if [[ "$sel_status" == "done" ]]; then
                        _list_execute_action "$sel_name" "Accept" "$tarvos_script" || break
                        _list_load_sessions
                        _list_tui_start
                    fi
                fi
                ;;

            r)
                # Reject selected session
                if (( count > 0 )); then
                    local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                    _list_execute_action "$sel_name" "Reject" "$tarvos_script" || break
                    _list_load_sessions
                    _list_tui_start
                fi
                ;;

            n)
                # New session
                _list_new_session_prompt "$tarvos_script"
                _list_load_sessions
                count=${#_LIST_NAMES[@]}
                (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                _list_tui_start
                ;;

            $'\x1b')
                # Arrow key escape sequence
                local seq="" arrow=""
                IFS= read -r -s -n1 -t 0.1 seq 2>/dev/null || true
                if [[ "$seq" == "[" ]]; then
                    IFS= read -r -s -n1 -t 0.1 arrow 2>/dev/null || true
                    case "$arrow" in
                        A)  # Up arrow
                            (( _LIST_SEL > 0 )) && (( _LIST_SEL-- ))
                            _list_render
                            ;;
                        B)  # Down arrow
                            (( count > 0 && _LIST_SEL < count - 1 )) && (( _LIST_SEL++ ))
                            _list_render
                            ;;
                    esac
                fi
                # If Escape alone (seq empty), just ignore — no double-render bug
                ;;

            "")
                # Enter key — show action overlay
                if (( count > 0 )); then
                    local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                    local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"

                    local action
                    action=$(_list_show_overlay "$sel_name" "$sel_status")

                    if [[ -n "$action" ]]; then
                        _list_execute_action "$sel_name" "$action" "$tarvos_script" || break
                        _list_load_sessions
                        count=${#_LIST_NAMES[@]}
                        (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                        # Re-initialize TUI after returning from subcommand
                        _list_tui_start
                    else
                        # Cancelled — just re-render cleanly (no double-render bug)
                        _list_render
                    fi
                fi
                ;;
        esac
    done

    _list_tui_stop
    trap - INT TERM EXIT
}
