#!/usr/bin/env bash
# tui-app.sh — Unified single-process TUI application for Tarvos
# Implements a screen stack: list → run view → summary overlay
# All screens share state in the same process (no nested smcup).
#
# Entry point: tui_app_run [tarvos_script]

# Guard against double-sourcing
[[ -n "${_TARVOS_TUI_APP_LOADED:-}" ]] && return 0
_TARVOS_TUI_APP_LOADED=1

# ──────────────────────────────────────────────────────────────
# Locate and source dependencies
# ──────────────────────────────────────────────────────────────
_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/tui-core.sh
source "${_APP_DIR}/tui-core.sh"
# shellcheck source=lib/list-tui.sh
source "${_APP_DIR}/list-tui.sh"
# shellcheck source=lib/log-manager.sh
source "${_APP_DIR}/log-manager.sh"

# ──────────────────────────────────────────────────────────────
# Screen stack state
# ──────────────────────────────────────────────────────────────
declare -a SCREEN_STACK=()   # stack of screen names: "list", "run", "summary"
ACTIVE_SCREEN=""
_APP_TARVOS_SCRIPT="tarvos"  # path to the tarvos main script

# Per-screen context
_APP_RUN_SESSION=""          # session name when run view is active
_APP_SUMMARY_SESSION=""      # session name when summary overlay is active

# ──────────────────────────────────────────────────────────────
# Screen stack management
# ──────────────────────────────────────────────────────────────

push_screen() {
    local name="$1"
    local session="${2:-}"

    SCREEN_STACK+=("$name")
    ACTIVE_SCREEN="$name"

    case "$name" in
        list)
            screen_list_init
            ;;
        run)
            _APP_RUN_SESSION="$session"
            screen_run_init "$session"
            ;;
        summary)
            _APP_SUMMARY_SESSION="$session"
            screen_summary_init "$session"
            ;;
    esac
}

pop_screen() {
    local stack_size=${#SCREEN_STACK[@]}
    if (( stack_size <= 1 )); then
        # Nothing to pop back to — quit entirely
        return 1
    fi

    # Cleanup current screen
    case "$ACTIVE_SCREEN" in
        run)
            screen_run_cleanup
            ;;
    esac

    # Remove last element from stack
    SCREEN_STACK=("${SCREEN_STACK[@]:0:$(( stack_size - 1 ))}")
    ACTIVE_SCREEN="${SCREEN_STACK[$(( stack_size - 2 ))]}"

    # Re-initialize the screen we're returning to
    case "$ACTIVE_SCREEN" in
        list)
            # Reload sessions and re-enter alternate screen
            _list_load_sessions
            local count=${#_LIST_NAMES[@]}
            (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
            _list_tui_start
            ;;
    esac

    return 0
}

# ──────────────────────────────────────────────────────────────
# List screen
# ──────────────────────────────────────────────────────────────

screen_list_init() {
    _list_load_sessions
    local count=${#_LIST_NAMES[@]}
    (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
    _list_tui_start
}

screen_list_render() {
    _list_render
}

# Returns:
#   0 = continue
#   1 = push run screen (session in _APP_RUN_SESSION)
#   2 = push summary screen
#   3 = quit
screen_list_key() {
    local key="$1"
    local count=${#_LIST_NAMES[@]}
    (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))

    case "$key" in
        q|Q)
            return 3
            ;;
        R)
            _list_load_sessions
            count=${#_LIST_NAMES[@]}
            (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
            _list_render
            ;;
        k)
            (( _LIST_SEL > 0 )) && (( _LIST_SEL-- ))
            _list_render
            ;;
        j)
            (( count > 0 && _LIST_SEL < count - 1 )) && (( _LIST_SEL++ ))
            _list_render
            ;;
        s)
            if (( count > 0 )); then
                local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"
                if [[ "$sel_status" == "initialized" ]]; then
                    _list_tui_stop
                    _list_execute_action "$sel_name" "Start" "$_APP_TARVOS_SCRIPT" || return 3
                    _list_load_sessions
                    _list_tui_start
                fi
            fi
            ;;
        b)
            if (( count > 0 )); then
                local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"
                local bg_action=""
                case "$sel_status" in
                    initialized) bg_action="Start (bg)" ;;
                    stopped)     bg_action="Resume (bg)" ;;
                esac
                if [[ -n "$bg_action" ]]; then
                    _list_tui_stop
                    _list_execute_action "$sel_name" "$bg_action" "$_APP_TARVOS_SCRIPT" || return 3
                    _list_load_sessions
                    _list_tui_start
                fi
            fi
            ;;
        a)
            if (( count > 0 )); then
                local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"
                if [[ "$sel_status" == "done" ]]; then
                    _list_tui_stop
                    _list_execute_action "$sel_name" "Accept" "$_APP_TARVOS_SCRIPT" || return 3
                    _list_load_sessions
                    _list_tui_start
                fi
            fi
            ;;
        r)
            if (( count > 0 )); then
                local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                _list_tui_stop
                _list_execute_action "$sel_name" "Reject" "$_APP_TARVOS_SCRIPT" || return 3
                _list_load_sessions
                _list_tui_start
            fi
            ;;
        n)
            _list_new_session_prompt "$_APP_TARVOS_SCRIPT"
            _list_load_sessions
            count=${#_LIST_NAMES[@]}
            (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
            _list_tui_start
            ;;
        $'\x1b')
            # Should not reach here — escape sequences are pre-processed by caller
            ;;
        "")
            # Enter — open action overlay or push run view for running sessions
            if (( count > 0 )); then
                local sel_name="${_LIST_NAMES[$_LIST_SEL]}"
                local sel_status="${_LIST_STATUSES[$_LIST_SEL]}"

                # If session has a summary, offer to push summary screen
                local summary_file="${SESSIONS_DIR:-.tarvos/sessions}/${sel_name}/summary.md"

                if [[ "$sel_status" == "running" ]]; then
                    # Push run view — show live log
                    _APP_RUN_SESSION="$sel_name"
                    return 1
                elif [[ "$sel_status" == "done" ]] && [[ -f "$summary_file" ]]; then
                    # Push summary overlay
                    _APP_SUMMARY_SESSION="$sel_name"
                    return 2
                else
                    # Show action overlay
                    local action
                    action=$(_list_show_overlay "$sel_name" "$sel_status")
                    if [[ -n "$action" ]]; then
                        _list_tui_stop
                        _list_execute_action "$sel_name" "$action" "$_APP_TARVOS_SCRIPT" || return 3
                        _list_load_sessions
                        count=${#_LIST_NAMES[@]}
                        (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                        _list_tui_start
                    else
                        _list_render
                    fi
                fi
            fi
            ;;
    esac
    return 0
}

# ──────────────────────────────────────────────────────────────
# Run view screen
# ──────────────────────────────────────────────────────────────

_APP_RUN_EVENTS_LOG=""   # current events log being tailed
_APP_RUN_INIT_DONE=0     # whether we've initialized the run view TUI

screen_run_init() {
    local session="$1"

    # Stop the list TUI's alternate screen (we take over with the run view TUI)
    _list_tui_stop

    # Re-init TUI for run view (alternate screen + cursor hide)
    TUI_ENABLED=1
    tc_screen_init
    CURRENT_SESSION_NAME="$session"

    # Find the most recent events log for this session
    local log_dir
    log_dir=$(ls -td ".tarvos/sessions/${session}/logs/run-"* 2>/dev/null | head -1 || true)
    if [[ -n "$log_dir" ]]; then
        # Find the highest-numbered events log
        local latest_events
        latest_events=$(ls -t "${log_dir}"/loop-*-events.jsonl 2>/dev/null | head -1 || true)
        if [[ -n "$latest_events" ]]; then
            _APP_RUN_EVENTS_LOG="$latest_events"
            _lm_tail_start "$latest_events"
            _LM_CURRENT_EVENTS_LOG="$latest_events"
        fi
    fi

    _APP_RUN_INIT_DONE=1
    tui_render
}

screen_run_render() {
    # Drain new events and re-render
    _lm_drain_events || true
    tui_render
}

# Returns:
#   0 = continue
#   1 = pop back to list (q)
#   2 = background detach (b)
screen_run_key() {
    local key="$1"
    tui_handle_key "$key"

    if [[ "$_LM_KEY_ACTION" == "quit" ]]; then
        return 1
    elif [[ "$_LM_KEY_ACTION" == "background" ]]; then
        return 2
    fi
    return 0
}

screen_run_cleanup() {
    _lm_tail_stop
    tc_screen_cleanup
    _APP_RUN_INIT_DONE=0
    TUI_ENABLED=0
}

# ──────────────────────────────────────────────────────────────
# Summary overlay screen
# ──────────────────────────────────────────────────────────────

screen_summary_init() {
    local session="$1"
    _list_tui_stop

    # Show the completion overlay (it has its own input loop)
    TUI_ENABLED=1
    tc_screen_init
    CURRENT_SESSION_NAME="$session"
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_ROWS=$(tput lines 2>/dev/null || echo 24)

    tui_show_completion_overlay "$session"

    # After overlay returns, clean up
    tc_screen_cleanup
    TUI_ENABLED=0
}

screen_summary_render() {
    # Summary init runs its own loop; render is a no-op here
    :
}

screen_summary_key() {
    # Summary manages its own keys; all keys here mean "pop back"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Main event loop
# ──────────────────────────────────────────────────────────────

tui_app_run() {
    local tarvos_script="${1:-tarvos}"
    _APP_TARVOS_SCRIPT="$tarvos_script"

    # Require jq
    if ! command -v jq &>/dev/null; then
        echo "tarvos: jq is required for the TUI. Install with: brew install jq" >&2
        return 1
    fi

    # Non-interactive fallback
    if [[ ! -t 1 ]]; then
        list_tui_run "$tarvos_script"
        return $?
    fi

    # Initialize screen stack with list screen
    tc_screen_init
    SCREEN_STACK=()
    push_screen "list"

    # Cleanup on exit
    trap '_app_cleanup; exit 0' INT TERM EXIT

    while true; do
        count=${#_LIST_NAMES[@]}

        # Non-blocking read (3s timeout for auto-refresh)
        local key=""
        IFS= read -r -s -n1 -t 3 key 2>/dev/null || true

        if [[ -z "$key" ]]; then
            # Timeout: auto-refresh on list screen, render update on run screen
            case "$ACTIVE_SCREEN" in
                list)
                    _list_load_sessions
                    count=${#_LIST_NAMES[@]}
                    (( _LIST_SEL >= count && count > 0 )) && _LIST_SEL=$(( count - 1 ))
                    screen_list_render
                    ;;
                run)
                    screen_run_render
                    ;;
            esac
            continue
        fi

        # Handle escape sequences (arrow keys)
        if [[ "$key" == $'\x1b' ]]; then
            local seq=""
            IFS= read -r -s -n2 -t 0.1 seq 2>/dev/null || true
            if [[ "$seq" == "[A" ]]; then
                key=$'\x1b[A'
            elif [[ "$seq" == "[B" ]]; then
                key=$'\x1b[B'
            elif [[ "$seq" == "[C" ]]; then
                key=$'\x1b[C'
            elif [[ "$seq" == "[D" ]]; then
                key=$'\x1b[D'
            elif [[ -z "$seq" ]]; then
                # Plain escape — map to empty for list overlay cancel
                key=$'\x1b'
            else
                key="${key}${seq}"
            fi
        fi

        # Dispatch key to active screen
        local key_result=0
        case "$ACTIVE_SCREEN" in
            list)
                # Map escape sequences to arrow keys for the list handler
                local mapped_key="$key"
                case "$key" in
                    $'\x1b[A') mapped_key=$'\x1b' ;;  # handled specially below
                    $'\x1b[B') mapped_key=$'\x1b' ;;
                esac
                if [[ "$key" == $'\x1b[A' ]]; then
                    # Up arrow in list context
                    (( _LIST_SEL > 0 )) && (( _LIST_SEL-- ))
                    _list_render
                elif [[ "$key" == $'\x1b[B' ]]; then
                    # Down arrow in list context
                    local lcount=${#_LIST_NAMES[@]}
                    (( lcount > 0 && _LIST_SEL < lcount - 1 )) && (( _LIST_SEL++ ))
                    _list_render
                else
                    screen_list_key "$key"
                    key_result=$?
                fi
                ;;
            run)
                screen_run_key "$key"
                key_result=$?
                ;;
            summary)
                screen_summary_key "$key"
                key_result=$?
                ;;
        esac

        # Handle navigation results
        case "$key_result" in
            1)
                # Pop back (or quit if at bottom of stack)
                if ! pop_screen; then
                    break
                fi
                ;;
            2)
                # Push run screen (from list Enter on running session)
                # OR background detach (from run view b key)
                if [[ "$ACTIVE_SCREEN" == "list" ]]; then
                    local sess="${_APP_RUN_SESSION:-${_LIST_NAMES[$_LIST_SEL]:-}}"
                    if [[ -n "$sess" ]]; then
                        push_screen "run" "$sess"
                    fi
                elif [[ "$ACTIVE_SCREEN" == "run" ]]; then
                    # Background detach — just pop back to list
                    if ! pop_screen; then
                        break
                    fi
                fi
                ;;
            3)
                # Quit entirely
                break
                ;;
        esac
    done

    _app_cleanup
    trap - INT TERM EXIT
}

_app_cleanup() {
    # Stop any active run view tail reader
    if [[ "$ACTIVE_SCREEN" == "run" ]]; then
        screen_run_cleanup
    else
        _list_tui_stop
        tc_screen_cleanup 2>/dev/null || true
    fi
}
