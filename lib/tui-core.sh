#!/usr/bin/env bash
# tui-core.sh — Shared TUI primitive library for Tarvos
# Provides 256-color palette, border drawing, spinner engine, progress bar,
# screen lifecycle, status icons, header, footer, and tiny animations.
# Source this file from any TUI component.

# Guard against double-sourcing
[[ -n "${_TARVOS_TUI_CORE_LOADED:-}" ]] && return 0
_TARVOS_TUI_CORE_LOADED=1

# ──────────────────────────────────────────────────────────────
# 256-color palette
# ──────────────────────────────────────────────────────────────

# Accent / brand
TC_ACCENT="\033[38;5;212m"        # gum pink — interactive highlights
TC_ACCENT_BG="\033[48;5;212m"
TC_PURPLE="\033[38;5;57m"         # deep purple — header background
TC_PURPLE_BG="\033[48;5;57m"

# Neutrals
TC_MUTED="\033[38;5;240m"         # dark gray — secondary text
TC_SUBTLE="\033[38;5;244m"        # medium gray
TC_NORMAL="\033[38;5;252m"        # near-white — body text

# Semantic
TC_SUCCESS="\033[38;5;82m"        # bright green
TC_WARNING="\033[38;5;214m"       # orange
TC_ERROR="\033[38;5;196m"         # bright red
TC_INFO="\033[38;5;75m"           # light blue

# Panel backgrounds
TC_PANEL_BG="\033[48;5;236m"      # #303030
TC_SEL_BG="\033[48;5;238m"        # selected row highlight
TC_HEADER_BG="\033[48;5;57m"      # deep purple header

# Standard modifiers
TC_BOLD="\033[1m"
TC_DIM="\033[2m"
TC_RESET="\033[0m"

# ──────────────────────────────────────────────────────────────
# Terminal dimensions (updated on SIGWINCH)
# ──────────────────────────────────────────────────────────────
TC_COLS=80
TC_ROWS=24
TC_RENDER_CALLBACK=""  # optional function name to call on resize

_tc_update_dimensions() {
    TC_COLS=$(tput cols  2>/dev/null || echo 80)
    TC_ROWS=$(tput lines 2>/dev/null || echo 24)
}

_tc_sigwinch_handler() {
    _tc_update_dimensions
    if [[ -n "$TC_RENDER_CALLBACK" ]]; then
        "$TC_RENDER_CALLBACK" 2>/dev/null || true
    fi
}

# ──────────────────────────────────────────────────────────────
# Screen lifecycle
# ──────────────────────────────────────────────────────────────

tc_screen_init() {
    _tc_update_dimensions
    trap '_tc_sigwinch_handler' WINCH
    tput smcup  2>/dev/null   # alternate screen
    tput civis  2>/dev/null   # hide cursor
    tput clear  2>/dev/null
}

tc_screen_cleanup() {
    tput cnorm  2>/dev/null   # restore cursor
    tput rmcup  2>/dev/null   # leave alternate screen
    trap - WINCH
}

# Safe positioned write — clips at terminal width
# tc_write(row, col, text)
tc_write() {
    local row="$1" col="$2" text="$3"
    tput cup "$row" "$col" 2>/dev/null
    # Strip ANSI for length calculation, then print actual text
    local plain
    plain=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null || printf '%b' "$text")
    local max_len=$(( TC_COLS - col ))
    if (( max_len <= 0 )); then return; fi
    if (( ${#plain} > max_len )); then
        # Truncate: we can't easily truncate colored strings, so just print and let terminal clip
        printf '%b' "$text"
    else
        printf '%b' "$text"
    fi
}

# ──────────────────────────────────────────────────────────────
# Border drawing (rounded corners — gum-inspired)
# ──────────────────────────────────────────────────────────────

# tc_draw_box_top(title, width, color)
# Draws: ╭─── Title ───╮
tc_draw_box_top() {
    local title="${1:-}" width="${2:-$TC_COLS}" color="${3:-$TC_NORMAL}"
    local reset="$TC_RESET"
    local inner=$(( width - 2 ))

    if [[ -n "$title" ]]; then
        local plain_title="$title"
        local title_len=${#plain_title}
        local left_dashes=$(( (inner - title_len - 2) / 2 ))
        local right_dashes=$(( inner - title_len - 2 - left_dashes ))
        [[ $left_dashes -lt 1 ]] && left_dashes=1
        [[ $right_dashes -lt 1 ]] && right_dashes=1
        local left_bar right_bar
        left_bar=$(printf '─%.0s' $(seq 1 $left_dashes))
        right_bar=$(printf '─%.0s' $(seq 1 $right_dashes))
        printf '%b' "${color}╭${left_bar} ${title} ${right_bar}╮${reset}"
    else
        local bar
        bar=$(printf '─%.0s' $(seq 1 $inner))
        printf '%b' "${color}╭${bar}╮${reset}"
    fi
    printf '\n'
}

# tc_draw_box_line(content, width, color)
# Draws: │  content    │
tc_draw_box_line() {
    local content="${1:-}" width="${2:-$TC_COLS}" color="${3:-$TC_NORMAL}"
    local reset="$TC_RESET"
    local inner=$(( width - 2 ))
    # Strip ANSI for length measurement
    local plain
    plain=$(printf '%b' "$content" | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null || printf '%b' "$content")
    local pad=$(( inner - ${#plain} ))
    [[ $pad -lt 0 ]] && pad=0
    local spaces
    spaces=$(printf '%*s' "$pad" '')
    printf '%b' "${color}│${reset}${content}${spaces}${color}│${reset}"
    printf '\n'
}

# tc_draw_box_bottom(width, color)
# Draws: ╰─────────────╯
tc_draw_box_bottom() {
    local width="${1:-$TC_COLS}" color="${2:-$TC_NORMAL}"
    local reset="$TC_RESET"
    local inner=$(( width - 2 ))
    local bar
    bar=$(printf '─%.0s' $(seq 1 $inner))
    printf '%b' "${color}╰${bar}╯${reset}"
    printf '\n'
}

# tc_draw_separator(width, style)
# style: "thin" (─), "dashed" (╌), "thick" (━)
tc_draw_separator() {
    local width="${1:-$TC_COLS}" style="${2:-thin}"
    local char
    case "$style" in
        dashed) char='╌' ;;
        thick)  char='━' ;;
        *)      char='─' ;;
    esac
    local bar
    bar=$(printf "${char}%.0s" $(seq 1 $width))
    printf '%b\n' "${TC_MUTED}${bar}${TC_RESET}"
}

# tc_draw_panel(title, row, col, width, height, color, content_array_name)
# Draws a full bordered panel at absolute cursor position.
# content_array_name: name of a bash array variable containing the content lines
tc_draw_panel() {
    local title="$1" row="$2" col="$3" width="$4" height="$5" color="${6:-$TC_NORMAL}"
    local content_array_name="${7:-}"
    local inner_height=$(( height - 2 ))

    tput cup "$row" "$col" 2>/dev/null
    tc_draw_box_top "$title" "$width" "$color"

    local i
    for (( i=0; i<inner_height; i++ )); do
        tput cup $(( row + 1 + i )) "$col" 2>/dev/null
        if [[ -n "$content_array_name" ]]; then
            local line=""
            eval "line=\"\${${content_array_name}[$i]:-}\""
            tc_draw_box_line "$line" "$width" "$color"
        else
            tc_draw_box_line "" "$width" "$color"
        fi
    done

    tput cup $(( row + height - 1 )) "$col" 2>/dev/null
    tc_draw_box_bottom "$width" "$color"
}

# ──────────────────────────────────────────────────────────────
# Braille spinner engine
# ──────────────────────────────────────────────────────────────
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_INTERVAL=0.08
TC_SPINNER_PID=""

# tc_spinner_start(row, col)
# Launch spinner in background subshell, write PID to TC_SPINNER_PID
tc_spinner_start() {
    local row="$1" col="$2"
    (
        local idx=0
        while true; do
            tput cup "$row" "$col" 2>/dev/null
            printf '%b' "${TC_SUCCESS}${SPINNER_FRAMES[$idx]}${TC_RESET}"
            idx=$(( (idx + 1) % ${#SPINNER_FRAMES[@]} ))
            sleep "$SPINNER_INTERVAL" 2>/dev/null || sleep 1
        done
    ) &
    TC_SPINNER_PID=$!
}

# tc_spinner_stop()
# Kill TC_SPINNER_PID and clear the spinner character
tc_spinner_stop() {
    if [[ -n "$TC_SPINNER_PID" ]] && kill -0 "$TC_SPINNER_PID" 2>/dev/null; then
        kill "$TC_SPINNER_PID" 2>/dev/null
        wait "$TC_SPINNER_PID" 2>/dev/null || true
    fi
    TC_SPINNER_PID=""
}

# Get the current spinner frame for a given index (for inline rendering)
# tc_spinner_frame(index) — returns the frame character
tc_spinner_frame() {
    local idx=$(( ${1:-0} % ${#SPINNER_FRAMES[@]} ))
    printf '%s' "${SPINNER_FRAMES[$idx]}"
}

# ──────────────────────────────────────────────────────────────
# Progress bar (block gradient style)
# ──────────────────────────────────────────────────────────────
# tc_draw_progress(pct, width)
# Returns string like: [▁▂▃▄▅▆▇███░░░░░░░░░] 42%
# Color: green (<60%), orange (≥60%), red (≥80%)
tc_draw_progress() {
    local pct="${1:-0}" width="${2:-20}"
    local bar_width=$(( width - 2 ))  # subtract brackets
    local filled=$(( pct * bar_width / 100 ))
    [[ $filled -lt 0 ]] && filled=0
    [[ $filled -gt $bar_width ]] && filled=$bar_width
    local empty=$(( bar_width - filled ))

    # Color based on percentage
    local color
    if (( pct >= 80 )); then
        color="$TC_ERROR"
    elif (( pct >= 60 )); then
        color="$TC_WARNING"
    else
        color="$TC_SUCCESS"
    fi

    # Build gradient fill using block characters
    local BLOCKS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do
        local block_idx=$(( i * 7 / (bar_width > 0 ? bar_width : 1) ))
        [[ $block_idx -gt 7 ]] && block_idx=7
        bar+="${BLOCKS[$block_idx]}"
    done
    for (( i=0; i<empty; i++ )); do
        bar+="░"
    done

    printf '%b' "${color}[${bar}]${TC_RESET} ${pct}%"
}

# ──────────────────────────────────────────────────────────────
# Status icon / color mapping
# ──────────────────────────────────────────────────────────────

# tc_status_icon(status) — returns icon character
tc_status_icon() {
    local status="$1"
    case "$status" in
        running|RUNNING)         printf '●' ;;
        done|DONE)               printf '✓' ;;
        stopped)                 printf '⏸' ;;
        failed|ERROR)            printf '✗' ;;
        initialized)             printf '○' ;;
        CONTEXT_LIMIT)           printf '!' ;;
        CONTINUATION)            printf '↻' ;;
        RECOVERY)                printf '⚠' ;;
        *)                       printf '?' ;;
    esac
}

# tc_status_color(status) — returns ANSI color code
tc_status_color() {
    local status="$1"
    case "$status" in
        running|RUNNING)         printf '%b' "$TC_SUCCESS" ;;
        done|DONE)               printf '%b' "$TC_INFO" ;;
        stopped)                 printf '%b' "$TC_WARNING" ;;
        failed|ERROR)            printf '%b' "$TC_ERROR" ;;
        initialized)             printf '%b' "$TC_MUTED" ;;
        CONTEXT_LIMIT)           printf '%b' "$TC_WARNING" ;;
        CONTINUATION)            printf '%b' "$TC_WARNING" ;;
        RECOVERY)                printf '%b' "$TC_ERROR" ;;
        *)                       printf '%b' "$TC_SUBTLE" ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# Header component
# ──────────────────────────────────────────────────────────────
# tc_draw_header([subtitle])
# Full-width deep purple background bar (2 rows)
# Row 1: "  🦥 TARVOS" in bold white + right-aligned current time
# Row 2: "  Autonomous AI Coding Orchestrator" (or custom subtitle) in dim muted text
tc_draw_header() {
    local subtitle="${1:-Autonomous AI Coding Orchestrator}"
    local width="$TC_COLS"
    local reset="$TC_RESET"
    local now
    now=$(date '+%H:%M:%S' 2>/dev/null || echo "??:??:??")

    # Row 1: brand + time
    local brand="  🦥 TARVOS"
    local brand_plain="  🦥 TARVOS"
    # 🦥 is a wide char (2 cols), so adjust visual length
    local brand_visual_len=$(( ${#brand_plain} + 1 ))  # +1 for wide emoji
    local time_len=${#now}
    local gap=$(( width - brand_visual_len - time_len - 2 ))
    [[ $gap -lt 1 ]] && gap=1
    local spaces
    spaces=$(printf '%*s' "$gap" '')

    tput cup 0 0 2>/dev/null
    printf '%b' "${TC_HEADER_BG}${TC_BOLD}${TC_NORMAL}"
    printf '%b' "${brand_plain}${spaces}${now}  "
    printf '%b' "${reset}"
    # Pad to full width
    local row1_content_len=$(( brand_visual_len + gap + time_len + 2 ))
    if (( row1_content_len < width )); then
        printf '%b' "${TC_HEADER_BG}%$((width - row1_content_len))s${reset}" ""
    fi
    printf '\n'

    # Row 2: subtitle
    tput cup 1 0 2>/dev/null
    local sub_text="  ${subtitle}"
    local sub_len=${#sub_text}
    local sub_pad=$(( width - sub_len ))
    [[ $sub_pad -lt 0 ]] && sub_pad=0
    printf '%b' "${TC_HEADER_BG}${TC_MUTED}${sub_text}"
    printf '%*s' "$sub_pad" ''
    printf '%b' "${reset}"
    printf '\n'
}

# ──────────────────────────────────────────────────────────────
# Footer / status bar
# ──────────────────────────────────────────────────────────────
# tc_draw_footer(key1, label1, key2, label2, ...)
# Last terminal row, dark background
# Renders key hints as [key] action pairs with accent-colored brackets
tc_draw_footer() {
    local hints=("$@")
    local width="$TC_COLS"
    local reset="$TC_RESET"

    tput cup $(( TC_ROWS - 1 )) 0 2>/dev/null
    printf '%b' "${TC_PANEL_BG}"

    local output=" "
    local i
    for (( i=0; i<${#hints[@]}; i+=2 )); do
        local key="${hints[$i]}"
        local label="${hints[$((i+1))]:-}"
        output+="${TC_ACCENT}[${key}]${TC_RESET}${TC_PANEL_BG} ${label}  "
    done

    printf '%b' "$output"

    # Pad to full width (strip ANSI for length)
    local plain
    plain=$(printf '%b' "$output" | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null || printf '%b' "$output")
    local pad=$(( width - ${#plain} ))
    [[ $pad -lt 0 ]] && pad=0
    printf '%*s' "$pad" ''
    printf '%b' "${reset}"
}

# ──────────────────────────────────────────────────────────────
# Tiny animations helpers
# ──────────────────────────────────────────────────────────────

# TC_RENDER_TICK — increment this each render cycle for animation effects
TC_RENDER_TICK=0

# tc_pulse_color(tick) — alternates between TC_SUCCESS and bright white for pulsing running sessions
tc_pulse_color() {
    local tick="${1:-$TC_RENDER_TICK}"
    if (( tick % 2 == 0 )); then
        printf '%b' "$TC_SUCCESS"
    else
        printf '%b' "\033[97m"  # bright white
    fi
}

# tc_flash_done_color(tick, settled_color) — flashes bold white for 2 ticks on DONE, then settles
tc_flash_done_color() {
    local tick="${1:-$TC_RENDER_TICK}" settled_color="${2:-$TC_INFO}"
    if (( tick < 2 )); then
        printf '%b' "${TC_BOLD}\033[97m"
    else
        printf '%b' "$settled_color"
    fi
}
