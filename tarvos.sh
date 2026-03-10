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

# Global session name (set by cmd_begin, used by shutdown trap)
CURRENT_SESSION_NAME=""

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
  --bg                Run session in background (detached mode)
  -h, --help          Show this help message

Behavior:
  - Requires a clean working directory (no uncommitted changes).
  - On first run: creates a 'tarvos/<name>-<timestamp>' branch and checks it out.
  - On resume:    checks out the existing session branch.
  - With --bg:    starts the session as a background process (nohup).
                  Use 'tarvos attach <name>' to follow live output.

Example:
  tarvos begin auth-feature
  tarvos begin auth-feature --continue
  tarvos begin auth-feature --bg

Run \`tarvos init <prd-path> --name <name>\` first to create a session.
EOF
    exit 0
}

usage_attach() {
    cat <<EOF
Usage: tarvos attach <session-name>

Tail the live output of a background session.
Press Ctrl+C to detach — the session continues running in the background.

Example:
  tarvos attach auth-feature
EOF
    exit 0
}

usage_stop() {
    cat <<EOF
Usage: tarvos stop <session-name>

Stop a running background session (SIGTERM, then SIGKILL after 2s).

Example:
  tarvos stop auth-feature
EOF
    exit 0
}

usage_list() {
    cat <<EOF
Usage: tarvos list

Show all sessions in an interactive TUI.

Navigation:
  ↑ / ↓    Move selection
  Enter     Open actions menu for selected session
  r         Refresh session list
  q         Quit

Actions (context-aware per session status):
  running     → Attach, Stop
  stopped     → Resume, Reject
  done        → Accept, Reject
  initialized → Start, Start (bg), Reject
  failed      → Reject
EOF
    exit 0
}

usage_accept() {
    cat <<EOF
Usage: tarvos accept <session-name>

Accept a completed session: merge its branch into the original branch,
archive the session folder, delete the session branch, and remove it
from the registry.

Requirements:
  - Session status must be 'done'
  - Working directory must be clean (no uncommitted changes)

Example:
  tarvos accept auth-feature
EOF
    exit 0
}

usage_reject() {
    cat <<EOF
Usage: tarvos reject <session-name> [--force]

Reject a session: delete its branch and session folder and remove it
from the registry.

Options:
  --force     Skip confirmation prompt

Requirements:
  - Session must not be currently running (stop it first)

Example:
  tarvos reject auth-feature
  tarvos reject auth-feature --force
EOF
    exit 0
}

usage_migrate() {
    cat <<EOF
Usage: tarvos migrate

Migrate a legacy Tarvos configuration (.tarvos/config) to the session-based
format introduced in the async ecosystem update.

What it does:
  - Reads PRD_FILE, TOKEN_LIMIT, and MAX_LOOPS from .tarvos/config
  - Creates a session named "default" in .tarvos/sessions/default/
  - Moves progress.md (if it exists) into the session folder
  - Archives the old config to .tarvos/config.bak

Example:
  tarvos migrate
EOF
    exit 0
}

usage_root() {
    cat <<EOF
Usage: tarvos <command> [options]

Tarvos orchestrates a chain of fresh AI agents on a single plan, each picking
up where the last left off. Every session runs on its own git branch — accept
good work, reject experiments, without touching git yourself.

Commands:
  init <prd-path> --name <name>   Create a new session
  begin <name>                    Run session agent loop (creates git branch)
  begin <name> --continue         Resume from existing progress checkpoint
  begin <name> --bg               Run session in the background (detached)
  attach <name>                   Follow live output of a background session
  stop <name>                     Stop a running background session
  list                            Show all sessions in an interactive TUI
  accept <name>                   Merge completed session branch and archive
  reject <name> [--force]         Delete session branch and remove session
  migrate                         Migrate legacy .tarvos/config to session format

Session lifecycle:
  init → begin → done → accept   (branch merged, session archived)
                      ↘ reject   (branch + session deleted)
         begin → stopped → begin  (resume later)
                         ↘ reject

Session status values:
  initialized   Created, not yet started
  running       Agent loop is active
  stopped       Paused (can be resumed with begin)
  done          All phases complete (ready to accept or reject)
  failed        Exceeded retries or hit an unrecoverable error

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

    # ── Git environment validation ──────────────────────────────
    # Scenario A: No git repo at all
    if ! git rev-parse --git-dir &>/dev/null; then
        cat <<'EOF'
tarvos: this directory is not a git repository.

  Tarvos requires git to isolate each PRD on its own branch.
  To initialize git here, run:

    git init
    git add .
    git commit -m "initial commit"

  Then re-run:

    tarvos init <your-prd.md> --name <session-name>
EOF
        exit 1
    fi

    # Scenario B: Git repo exists — ensure .tarvos/ is in .gitignore
    if [[ ! -f ".gitignore" ]]; then
        printf '.tarvos/\n' > ".gitignore"
        echo "  ✓ Created .gitignore with .tarvos/"
    elif ! grep -qxF '.tarvos/' ".gitignore" 2>/dev/null; then
        printf '\n.tarvos/\n' >> ".gitignore"
        echo "  ✓ Added .tarvos/ to .gitignore"
    fi
    # (If .gitignore already has .tarvos/ — do nothing, idempotent)
    # ────────────────────────────────────────────────────────────

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
    local bg_mode=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_begin ;;
            --continue) continue_mode=1; shift ;;
            --bg)       bg_mode=1; shift ;;
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

    # Source session manager, branch manager, and detach manager
    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/branch-manager.sh"
    source "${SCRIPT_DIR}/lib/detach-manager.sh"

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

    # ── Branch isolation ────────────────────────────────────────
    # Ensure git working directory is clean before touching branches
    if ! branch_ensure_clean; then
        exit 1
    fi

    if [[ "$SESSION_STATUS" == "initialized" ]]; then
        # Fresh session: record original branch, create tarvos/* branch
        local original_branch
        if ! original_branch=$(branch_get_current); then
            exit 1
        fi

        local new_branch
        if ! new_branch=$(branch_create "$session_name"); then
            exit 1
        fi

        echo "tarvos: created branch '${new_branch}'"

        # Persist branch info into session state
        session_set_branch "$session_name" "$new_branch" "$original_branch"

        # Reload so SESSION_BRANCH / SESSION_ORIGINAL_BRANCH are current
        session_load "$session_name"
    else
        # Resumed session: checkout the existing session branch
        if [[ -n "$SESSION_BRANCH" ]]; then
            if ! branch_checkout "$SESSION_BRANCH"; then
                exit 1
            fi
            echo "tarvos: checked out branch '${SESSION_BRANCH}'"
        fi
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

    # ── Background / detached mode ──────────────────────────────
    if (( bg_mode )); then
        # Check that the session isn't already running in background
        if detach_is_running "$session_name"; then
            local existing_pid
            existing_pid=$(detach_get_pid "$session_name")
            echo "tarvos begin: session '${session_name}' is already running in the background (PID: ${existing_pid})." >&2
            exit 1
        fi

        # Mark session as running before we hand off to nohup
        session_set_status "$session_name" "running"
        session_mark_started "$session_name"

        detach_start "$session_name" "${SCRIPT_DIR}/tarvos.sh" "$PROJECT_DIR"
        exit 0
    fi

    # ── Foreground mode ─────────────────────────────────────────
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
# tarvos attach — follow live output of a background session
# ──────────────────────────────────────────────────────────────
cmd_attach() {
    local session_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_attach ;;
            -*)
                echo "tarvos attach: unknown option: $1" >&2
                usage_attach
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos attach: unexpected argument: $1" >&2
                    usage_attach
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos attach: missing required argument <session-name>" >&2
        usage_attach
    fi

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/detach-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos attach: session '${session_name}' not found." >&2
        exit 1
    fi

    detach_attach "$session_name"
}

# ──────────────────────────────────────────────────────────────
# tarvos stop — stop a running background session
# ──────────────────────────────────────────────────────────────
cmd_stop() {
    local session_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_stop ;;
            -*)
                echo "tarvos stop: unknown option: $1" >&2
                usage_stop
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos stop: unexpected argument: $1" >&2
                    usage_stop
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos stop: missing required argument <session-name>" >&2
        usage_stop
    fi

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/detach-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos stop: session '${session_name}' not found." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    if [[ "$SESSION_STATUS" != "running" ]]; then
        echo "tarvos stop: session '${session_name}' is not running (status: ${SESSION_STATUS})." >&2
        exit 1
    fi

    if ! detach_is_running "$session_name"; then
        echo "tarvos stop: session '${session_name}' has no active background process." >&2
        echo "  It may be a foreground session. Use Ctrl+C to stop it." >&2
        exit 1
    fi

    local pid
    pid=$(detach_get_pid "$session_name")
    echo "Stopping session '${session_name}' (PID: ${pid})..."

    if detach_stop "$session_name"; then
        echo "Session '${session_name}' stopped."
    else
        echo "tarvos stop: failed to stop session '${session_name}'." >&2
        exit 1
    fi
}

# ──────────────────────────────────────────────────────────────
# tarvos list — interactive session list TUI
# ──────────────────────────────────────────────────────────────
cmd_list() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_list ;;
            *)
                echo "tarvos list: unexpected argument: $1" >&2
                usage_list
                ;;
        esac
    done

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/list-tui.sh"

    list_tui_run "${SCRIPT_DIR}/tarvos.sh"
}

# ──────────────────────────────────────────────────────────────
# tarvos accept — merge session branch and archive session
# ──────────────────────────────────────────────────────────────
cmd_accept() {
    local session_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_accept ;;
            -*)
                echo "tarvos accept: unknown option: $1" >&2
                usage_accept
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos accept: unexpected argument: $1" >&2
                    usage_accept
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos accept: missing required argument <session-name>" >&2
        usage_accept
    fi

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/branch-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos accept: session '${session_name}' not found." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    # 1. Validate session status is 'done'
    if [[ "$SESSION_STATUS" != "done" ]]; then
        echo "tarvos accept: session '${session_name}' is not done (status: ${SESSION_STATUS})." >&2
        if [[ "$SESSION_STATUS" == "running" ]]; then
            echo "  Stop the session first: tarvos stop ${session_name}" >&2
        fi
        exit 1
    fi

    # 2. Ensure working directory is clean
    if ! branch_ensure_clean; then
        exit 1
    fi

    local source_branch="$SESSION_BRANCH"
    local target_branch="$SESSION_ORIGINAL_BRANCH"

    if [[ -z "$source_branch" ]]; then
        echo "tarvos accept: session '${session_name}' has no associated branch." >&2
        exit 1
    fi

    if [[ -z "$target_branch" ]]; then
        echo "tarvos accept: session '${session_name}' has no original branch recorded." >&2
        exit 1
    fi

    echo "Accepting session '${session_name}'..."
    echo "  Merging '${source_branch}' → '${target_branch}'"

    # 4. Attempt merge (branch_merge checks out target and merges source)
    if ! branch_merge "$source_branch" "$target_branch"; then
        # branch_merge already printed resolution instructions
        exit 1
    fi

    echo "  Merge successful."

    # 5. Archive session folder
    echo "  Archiving session..."
    session_archive "$session_name"

    # 6. Delete session branch
    echo "  Deleting branch '${source_branch}'..."
    branch_delete "$source_branch"

    # (registry_remove is already called by session_archive)

    echo ""
    echo "Session '${session_name}' accepted and merged into '${target_branch}'."
    echo "Session archived to .tarvos/archive/${session_name}-*/"
}

# ──────────────────────────────────────────────────────────────
# tarvos reject — delete session branch and folder
# ──────────────────────────────────────────────────────────────
cmd_reject() {
    local session_name=""
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_reject ;;
            --force)   force=1; shift ;;
            -*)
                echo "tarvos reject: unknown option: $1" >&2
                usage_reject
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos reject: unexpected argument: $1" >&2
                    usage_reject
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos reject: missing required argument <session-name>" >&2
        usage_reject
    fi

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/branch-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos reject: session '${session_name}' not found." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    # 2. Error if session is running
    if [[ "$SESSION_STATUS" == "running" ]]; then
        echo "tarvos reject: session '${session_name}' is currently running." >&2
        echo "  Stop it first: tarvos stop ${session_name}" >&2
        exit 1
    fi

    # 1. Prompt confirmation unless --force
    if (( ! force )); then
        local branch_info=""
        if [[ -n "$SESSION_BRANCH" ]]; then
            branch_info=" (branch: ${SESSION_BRANCH})"
        fi
        echo "Reject session '${session_name}'${branch_info}?"
        echo "  This will delete the session branch and all session data."
        printf "  Type 'yes' to confirm: "
        local confirm
        IFS= read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Rejection cancelled."
            exit 0
        fi
    fi

    echo "Rejecting session '${session_name}'..."

    # 3. Delete session branch (if exists)
    if [[ -n "$SESSION_BRANCH" ]]; then
        # Switch away from the session branch if we're on it
        local current_branch
        current_branch=$(branch_get_current 2>/dev/null || true)
        if [[ "$current_branch" == "$SESSION_BRANCH" ]]; then
            local fallback_branch="${SESSION_ORIGINAL_BRANCH:-main}"
            echo "  Switching to '${fallback_branch}' before deleting branch..."
            if ! git checkout "$fallback_branch" 2>/dev/null; then
                # Fallback: try main, master, or any existing branch
                local any_branch
                any_branch=$(git branch --format='%(refname:short)' | grep -v "^${SESSION_BRANCH}$" | head -1 2>/dev/null || true)
                if [[ -n "$any_branch" ]]; then
                    git checkout "$any_branch" 2>/dev/null || true
                fi
            fi
        fi
        echo "  Deleting branch '${SESSION_BRANCH}'..."
        branch_delete "$SESSION_BRANCH" || true
    fi

    # 4. Delete session folder and remove from registry
    echo "  Removing session data..."
    session_delete "$session_name"

    echo ""
    echo "Session '${session_name}' rejected and removed."
}

# ──────────────────────────────────────────────────────────────
# tarvos migrate — migrate legacy .tarvos/config to session format
# ──────────────────────────────────────────────────────────────
cmd_migrate() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_migrate ;;
            *)
                echo "tarvos migrate: unexpected argument: $1" >&2
                usage_migrate
                ;;
        esac
    done

    local BOLD='\033[1m' RESET='\033[0m' GREEN='\033[0;32m' YELLOW='\033[1;33m' DIM='\033[2m'

    # Detect legacy config
    local legacy_config=".tarvos/config"
    if [[ ! -f "$legacy_config" ]]; then
        echo "tarvos migrate: no legacy config found at ${legacy_config}." >&2
        if [[ -d ".tarvos/sessions" ]]; then
            echo "  Your project already uses the session-based format." >&2
        fi
        exit 1
    fi

    # Check that sessions folder doesn't already contain a "default" session
    source "${SCRIPT_DIR}/lib/session-manager.sh"
    if session_exists "default"; then
        echo "tarvos migrate: a session named 'default' already exists." >&2
        echo "  Please rename or remove it before migrating." >&2
        exit 1
    fi

    echo -e "${BOLD}Tarvos — Migrating legacy configuration${RESET}"
    echo ""

    # Read KEY=VALUE pairs from legacy config
    local prd_file="" token_limit="$DEFAULT_TOKEN_LIMIT" max_loops="$DEFAULT_MAX_LOOPS"
    local key value
    while IFS='=' read -r key value; do
        # Skip blank lines and comments
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        case "$key" in
            PRD_FILE)    prd_file="$value" ;;
            TOKEN_LIMIT) token_limit="$value" ;;
            MAX_LOOPS)   max_loops="$value" ;;
        esac
    done < "$legacy_config"

    if [[ -z "$prd_file" ]]; then
        echo "tarvos migrate: legacy config is missing PRD_FILE." >&2
        exit 1
    fi

    if [[ ! -f "$prd_file" ]]; then
        echo "tarvos migrate: PRD file from legacy config not found: ${prd_file}" >&2
        echo "  Update the path in ${legacy_config} before migrating." >&2
        exit 1
    fi

    echo -e "  ${BOLD}Legacy config:${RESET}  ${legacy_config}"
    echo -e "  ${BOLD}PRD file:${RESET}       ${prd_file}"
    echo -e "  ${BOLD}Token limit:${RESET}    ${token_limit}"
    echo -e "  ${BOLD}Max loops:${RESET}      ${max_loops}"
    echo ""

    # Validate jq is available
    if ! command -v jq &>/dev/null; then
        echo "tarvos migrate: jq is required but not installed. Install with: brew install jq" >&2
        exit 1
    fi

    mkdir -p "$TARVOS_DIR"

    # Create the "default" session
    echo -e "  ${DIM}Creating session 'default'...${RESET}"
    if ! session_init "default" "$prd_file" "$token_limit" "$max_loops"; then
        exit 1
    fi

    # Move progress.md into the session folder (if it exists in project root)
    local project_dir
    project_dir="$(pwd)"
    local old_progress="${project_dir}/progress.md"
    local new_progress="${SESSIONS_DIR}/default/progress.md"

    if [[ -f "$old_progress" ]]; then
        echo -e "  ${DIM}Moving progress.md to session folder...${RESET}"
        mv "$old_progress" "$new_progress"
    fi

    # Archive old config
    echo -e "  ${DIM}Archiving legacy config to .tarvos/config.bak...${RESET}"
    mv "$legacy_config" "${legacy_config}.bak"

    echo ""
    echo -e "  ${GREEN}${BOLD}Migration complete.${RESET}"
    echo -e "  Session 'default' created at: .tarvos/sessions/default/"
    if [[ -f "$new_progress" ]]; then
        echo -e "  Progress report moved to: .tarvos/sessions/default/progress.md"
    fi
    echo -e "  Legacy config backed up to: .tarvos/config.bak"
    echo ""
    echo -e "  Run ${BOLD}tarvos begin default${RESET} to continue where you left off."
    echo ""
}

# ──────────────────────────────────────────────────────────────
# Clean shutdown: kill claude, restore terminal, exit
# CURRENT_SESSION_NAME is set by cmd_begin before run_agent_loop
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

    # Update session state to stopped if a session is active
    if [[ -n "${CURRENT_SESSION_NAME:-}" ]]; then
        if declare -f session_set_status &>/dev/null; then
            session_set_status "$CURRENT_SESSION_NAME" "stopped" 2>/dev/null || true
        fi
        # Clean up pid file for detached sessions
        local pid_file="${SESSIONS_DIR:-'.tarvos/sessions'}/${CURRENT_SESSION_NAME}/pid"
        rm -f "$pid_file" 2>/dev/null || true
    fi

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

    local raw_log text_output stderr_log events_log
    raw_log=$(get_raw_log "$loop_num")
    events_log=$(get_events_log "$loop_num")
    text_output=$(mktemp)
    stderr_log=$(get_stderr_log "$loop_num")

    # Initialize events log for this loop (enables emit_tui_event in context-monitor.sh)
    set_events_log "$events_log"
    # Start the TUI event tail reader so the run view receives live updates
    tui_start_events_tail "$loop_num"

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
        continuation_prompt=$(build_context_limit_prompt "${PROGRESS_FILE:-}")
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
        init)    cmd_init "$@" ;;
        begin)   cmd_begin "$@" ;;
        attach)  cmd_attach "$@" ;;
        stop)    cmd_stop "$@" ;;
        list)    cmd_list "$@" ;;
        accept)  cmd_accept "$@" ;;
        reject)  cmd_reject "$@" ;;
        migrate) cmd_migrate "$@" ;;
        -h|--help) usage_root ;;
        *)
            echo "tarvos: unknown command: ${cmd}" >&2
            echo "Run \`tarvos --help\` for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
