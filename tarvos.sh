#!/usr/bin/env bash
set -uo pipefail
# NOTE: set -e intentionally omitted — it's incompatible with complex TUI rendering
# and bash arithmetic. Errors are handled explicitly where needed.

# Tarvos - AI Coding Agent Orchestrator
# Runs Claude Code agents in a loop on a single master plan (.prd.md)
# Each agent works on one phase, then hands off to a fresh agent via progress.md
#
# Usage:
#   tarvos init <prd-path> --name <name> [--token-limit N] [--max-loops N]
#   tarvos begin <name>
#   tarvos continue <name>

# Resolve script directory (where lib/ and protocol live)
# Dereference symlinks so SCRIPT_DIR always points to the real repo directory,
# not the directory containing the symlink (e.g. /usr/local/bin).
_TARVOS_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_TARVOS_SOURCE" ]]; do
    _TARVOS_SOURCE="$(readlink "$_TARVOS_SOURCE")"
done
SCRIPT_DIR="$(cd "$(dirname "$_TARVOS_SOURCE")" && pwd)"
unset _TARVOS_SOURCE

# ─── Note for developers ─────────────────────────────────────────────────────
# bun is NOT required at runtime. It is only needed to rebuild the TUI binary.
# See tui/build.sh for development instructions.

TARVOS_REPO="Photon48/tarvos"

# ─── Bundled dependency resolution ───────────────────────────────────────────
TARVOS_DATA_DIR="${TARVOS_DATA_DIR:-${HOME}/.local/share/tarvos}"

# Resolve bundled jq — prefer bundled copy, fall back to system jq
TARVOS_JQ="${TARVOS_JQ_PATH:-${TARVOS_DATA_DIR}/bin/jq}"
if [[ ! -x "$TARVOS_JQ" ]]; then
    TARVOS_JQ="$(command -v jq 2>/dev/null || true)"
fi
if [[ -z "$TARVOS_JQ" ]]; then
    echo "Error: jq not found. Re-run the tarvos installer:" >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/${TARVOS_REPO}/main/install.sh | bash" >&2
    exit 1
fi
export TARVOS_JQ

# Resolve TUI binary (priority: env var → installed → dev build)
_TUI_BIN="${TUI_BIN_PATH:-}"
if [[ -z "$_TUI_BIN" || ! -x "$_TUI_BIN" ]]; then
    _TUI_BIN="${TARVOS_DATA_DIR}/bin/tui"
fi
if [[ ! -x "$_TUI_BIN" ]]; then
    # Dev fallback: look for locally compiled binary
    _OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    _ARCH="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')"
    _TUI_BIN="${SCRIPT_DIR}/tui/dist/tui-${_OS}-${_ARCH}"
fi

# Capture the user's project root (where tarvos is invoked from).
# Must be done before any cd.  Inherited by background workers via the
# TARVOS_PROJECT_ROOT env var exported in the detach wrapper.
if [[ -z "${TARVOS_PROJECT_ROOT:-}" ]]; then
    TARVOS_PROJECT_ROOT="$(pwd)"
fi
export TARVOS_PROJECT_ROOT

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
# Utility: print an error message to stderr
# ──────────────────────────────────────────────────────────────
error() {
    echo "error: $*" >&2
}

# ──────────────────────────────────────────────────────────────
usage_init() {
    cat <<EOF
Usage: tarvos init <plan.md> --name <session-name> [options]

Create a new session from a plan file. Tarvos previews the plan and sets
up an isolated workspace (git branch + worktree) ready to run.

Options:
  --name <name>       Session name (required, alphanumeric + hyphens)
  --token-limit <N>   Max tokens per agent before handing off (default: ${DEFAULT_TOKEN_LIMIT})
  --max-loops <N>     Max agent iterations before stopping (default: ${DEFAULT_MAX_LOOPS})
  --no-preview        Skip the plan preview and create the session immediately
  -h, --help          Show this help message

Example:
  tarvos init ./my-plan.md --name auth-feature
  tarvos init ./my-plan.md --name bugfix --token-limit 80000
  tarvos init ./my-plan.md --name new-api --no-preview
EOF
    exit 0
}

usage_begin() {
    cat <<EOF
Usage: tarvos begin <session-name>

Start the agent loop for a session. Runs in the background — use
'tarvos tui' to monitor progress.

Options:
  -h, --help          Show this help message

Example:
  tarvos begin auth-feature

Run \`tarvos init <plan.md> --name <name>\` first to create a session.
EOF
    exit 0
}

usage_continue() {
    cat <<EOF
Usage: tarvos continue <session-name>

Resume a stopped session from where it left off. Picks up from the
existing progress checkpoint — no work is lost.

Options:
  -h, --help          Show this help message

Example:
  tarvos continue auth-feature
EOF
    exit 0
}

usage_attach() {
    cat <<EOF
Usage: tarvos attach <session-name>

Follow the live log output of a running session.
Press Ctrl+C to stop following — the session keeps running.

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

usage_tui() {
    cat <<EOF
Usage: tarvos tui [view <session-name>]

Open the interactive session browser (also: run 'tarvos' with no arguments).
  tarvos tui view <session>   Open directly to the RunDashboard for <session>

Keys:
  ↑ / k    Move selection up
  ↓ / j    Move selection down
  Enter     Open run view (running sessions) or actions menu
  s         Start selected initialized session
  a         Accept selected done session
  r         Reject selected session
  n         New session (prompts for name + PRD path)
  R         Force refresh
  q         Quit

Actions menu (context-aware per session status):
  running     → View, Stop
  stopped     → Continue, Reject
  done        → Accept, Reject, View Summary
  initialized → Start, Reject
  failed      → Reject
EOF
    exit 0
}

usage_accept() {
    cat <<EOF
Usage: tarvos accept <session-name>

Merge a completed session's changes into your branch and clean up.
Session must have status 'done'.

Example:
  tarvos accept auth-feature
EOF
    exit 0
}

usage_reject() {
    cat <<EOF
Usage: tarvos reject <session-name> [--force]

Discard a session — deletes the branch and all session data.
The session must not be currently running (use 'tarvos stop' first).

Options:
  --force     Skip the confirmation prompt

Example:
  tarvos reject auth-feature
  tarvos reject auth-feature --force
EOF
    exit 0
}

usage_forget() {
    cat <<EOF
Usage: tarvos forget <session-name> [--force]

Detaches a session from Tarvos without deleting its git branch.

The session's worktree is removed (if present) and its Tarvos metadata is
archived. The git branch is left exactly as-is — you can check it out,
merge it manually, open a PR, or delete it yourself.

Use this when you want to handle the branch outside of Tarvos.

Options:
  --force    Skip confirmation prompt

Status:    done, failed
EOF
    exit 0
}

usage_migrate() {
    cat <<EOF
Usage: tarvos migrate

Upgrade from an older version of Tarvos. Converts the legacy .tarvos/config
format to the current session-based format.

Example:
  tarvos migrate
EOF
    exit 0
}

usage_update() {
    cat <<EOF
Usage: tarvos update [--version <tag>] [--force]

Download and install a new version of Tarvos.

Options:
  --version <tag>   Install a specific release tag (e.g. v0.2.0).
                    If omitted, fetches the latest tag from GitHub.
  --force           Re-download jq even if it is already installed.
  -h, --help        Show this help message.

Examples:
  tarvos update                    # Update to the latest release
  tarvos update --version v0.2.0   # Install a specific version
  tarvos update --force            # Force re-download of all binaries
EOF
    exit 0
}

usage_root() {
    cat <<EOF
Usage: tarvos <command> [options]

Tarvos runs your AI coding plan to completion. Write a plan, start a session,
and let it work — each agent hands off to the next so nothing gets lost. When
you're happy with the result, accept it; if not, reject it and nothing changes.

Commands:
  init <plan.md> --name <name>    Create a new session from a plan file
  begin <name>                    Start a session (runs in the background)
  continue <name>                 Resume a stopped session
  tui                             Open the session browser (same as just 'tarvos')
  stop <name>                     Stop a running session
  accept <name>                   Merge the session's changes into your branch
  reject <name> [--force]         Discard a session and all its changes
  forget <name> [--force]         Remove from Tarvos; keep the git branch
  migrate                         Upgrade from an older Tarvos version
  update [--version <tag>]        Update Tarvos to a newer release

Session status:
  initialized   Ready to start
  running       Working
  stopped       Paused — resume with 'tarvos continue'
  done          Complete — accept or reject
  failed        Something went wrong — reject and try again

Run \`tarvos <command> --help\` for details on any command.
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
# Private helpers (no CLI parsing, no prompts)
# ──────────────────────────────────────────────────────────────

# _tarvos_reject_force <session_name>
# Core reject logic: worktree remove, branch delete, session delete.
# Callers must have already sourced session-manager, branch-manager,
# worktree-manager, and called session_load so SESSION_BRANCH is set.
# Does NOT prompt for confirmation.
_tarvos_reject_force() {
    local session_name="$1"

    if worktree_exists "$session_name"; then
        worktree_remove "$session_name" || true
    fi

    if [[ -n "${SESSION_BRANCH:-}" ]]; then
        branch_delete "$SESSION_BRANCH" || true
    fi

    session_delete "$session_name"
}

# _tarvos_reinit_session <prd_file> <session_name> <token_limit> <max_loops>
# Core init logic: calls session_init only. No CLI parsing, no PRD preview.
_tarvos_reinit_session() {
    local prd_file="$1"
    local session_name="$2"
    local token_limit="$3"
    local max_loops="$4"

    session_init "$session_name" "$prd_file" "$token_limit" "$max_loops"
}

# ──────────────────────────────────────────────────────────────
# tarvos begin — reads config then runs the agent loop
# ──────────────────────────────────────────────────────────────
cmd_begin() {
    local session_name=""
    local continue_mode=0
    local force_detach=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_begin ;;
            --detach)
                force_detach=1
                shift
                ;;
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
    if ! command -v claude &>/dev/null; then
        echo "tarvos begin: claude CLI not found in PATH." >&2
        exit 1
    fi

    # Source session manager, branch manager, worktree manager, and detach manager
    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/branch-manager.sh"
    source "${SCRIPT_DIR}/lib/worktree-manager.sh"
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
            # If stdin is not a tty (i.e., called from a detach wrapper), go straight
            # to the agent loop — the session was already set up by the foreground call.
            if [[ ! -t 0 ]]; then
                : # fall through to agent loop below
            else
                echo "Session '${session_name}' is currently running."
                printf "Would you like to reset and restart the implementation? [y/N]: "
                local running_answer
                IFS= read -r running_answer </dev/tty
                case "$running_answer" in
                    y|Y)
                        echo "Stopping and resetting session '${session_name}'..."

                        local saved_prd_running="$SESSION_PRD_FILE"
                        local saved_token_limit_running="$SESSION_TOKEN_LIMIT"
                        local saved_max_loops_running="$SESSION_MAX_LOOPS"

                        # Stop the background process if it has a PID file
                        if detach_is_running "$session_name"; then
                            detach_stop "$session_name" || true
                        fi

                        _tarvos_reject_force "$session_name"

                        if ! _tarvos_reinit_session "$saved_prd_running" "$session_name" "$saved_token_limit_running" "$saved_max_loops_running"; then
                            echo "tarvos begin: failed to re-initialize session '${session_name}'." >&2
                            exit 1
                        fi

                        # Reload so SESSION_STATUS is now "initialized"; branch+worktree
                        # creation is handled by the normal initialized path below.
                        session_load "$session_name" || exit 1
                        ;;
                    *)
                        echo "View it in the TUI: tarvos tui"
                        exit 0
                        ;;
                esac
            fi
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

    # ── Branch + Worktree isolation ─────────────────────────────
    # Ensure git working directory is clean before touching branches
    if ! branch_ensure_clean; then
        exit 1
    fi

    local WORKTREE_PATH=""

    if [[ "$SESSION_STATUS" == "initialized" ]]; then
        # Fresh session: record original branch, create tarvos/* branch,
        # then create an isolated worktree for it (no checkout in main tree)
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

        # Create a git worktree for the new branch
        local abs_wt_path
        if ! abs_wt_path=$(worktree_create "$session_name" "$new_branch"); then
            echo "tarvos: failed to create worktree for session '${session_name}'." >&2
            exit 1
        fi

        echo "tarvos: worktree at '$(worktree_path "${session_name}")'"

        # Persist worktree path into session state
        session_set_worktree_path "$session_name" "$abs_wt_path"

        WORKTREE_PATH="$abs_wt_path"

        # Reload so all SESSION_* vars are current
        session_load "$session_name"
    else
        # Stopped session
        if [[ ! -t 0 ]]; then
            # Non-interactive (background detach): resume in-progress work directly
            # (worktree and branch already exist — use SESSION_WORKTREE_PATH)
            if [[ -n "${SESSION_WORKTREE_PATH:-}" ]]; then
                WORKTREE_PATH="$SESSION_WORKTREE_PATH"
            fi
            continue_mode=1
        else
            # Interactive — safety prompt before discarding in-progress work
            echo "Session '${session_name}' has an implementation in progress."
            echo "Starting fresh will discard all existing progress and reset the implementation."
            printf "Are you sure you want to start over? [y/N]: "
            local restart_answer
            IFS= read -r restart_answer </dev/tty
            case "$restart_answer" in
                y|Y)
                    # User confirmed: reject old session and re-init with same settings
                    echo "Resetting session '${session_name}'..."

                    local saved_prd="$SESSION_PRD_FILE"
                    local saved_token_limit="$SESSION_TOKEN_LIMIT"
                    local saved_max_loops="$SESSION_MAX_LOOPS"

                    _tarvos_reject_force "$session_name"

                    if ! _tarvos_reinit_session "$saved_prd" "$session_name" "$saved_token_limit" "$saved_max_loops"; then
                        echo "tarvos begin: failed to re-initialize session '${session_name}'." >&2
                        exit 1
                    fi

                    # Reload freshly created session and create branch + worktree (same as initialized path)
                    session_load "$session_name" || exit 1

                    local original_branch
                    if ! original_branch=$(branch_get_current); then
                        exit 1
                    fi

                    local new_branch
                    if ! new_branch=$(branch_create "$session_name"); then
                        exit 1
                    fi

                    echo "tarvos: created branch '${new_branch}'"
                    session_set_branch "$session_name" "$new_branch" "$original_branch"

                    local abs_wt_path
                    if ! abs_wt_path=$(worktree_create "$session_name" "$new_branch"); then
                        echo "tarvos: failed to create worktree for session '${session_name}'." >&2
                        exit 1
                    fi

                    echo "tarvos: worktree at '$(worktree_path "${session_name}")'"
                    session_set_worktree_path "$session_name" "$abs_wt_path"
                    WORKTREE_PATH="$abs_wt_path"
                    session_load "$session_name"
                    ;;
                *)
                    echo "Use 'tarvos continue ${session_name}' to resume where it left off."
                    exit 0
                    ;;
            esac
        fi
    fi

    # Protocol file (SKILL.md in the tarvos-skill folder)
    local PROTOCOL_FILE="${SCRIPT_DIR}/tarvos-skill/SKILL.md"
    if [[ ! -f "$PROTOCOL_FILE" ]]; then
        echo "tarvos begin: skill file not found: $PROTOCOL_FILE" >&2
        exit 1
    fi

    # Project directory: use the worktree for isolation — hard abort if missing
    local PROJECT_DIR
    if [[ -z "$WORKTREE_PATH" ]]; then
        error "No worktree path found for session '${session_name}'. Cannot continue."
        exit 1
    fi
    if [[ ! -d "$WORKTREE_PATH" ]]; then
        error "Worktree directory '${WORKTREE_PATH}' does not exist."
        error "It may have been manually deleted. To clean up: tarvos reject ${session_name}"
        exit 1
    fi
    PROJECT_DIR="$WORKTREE_PATH"

    # ── Detached (background) mode ──────────────────────────────
    # Two cases for running the agent loop inline (we ARE the background worker):
    #   1. stdin is not a tty AND --detach was NOT passed (normal nohup wrapper invocation)
    # Otherwise, always detach to background.
    if [[ ! -t 0 ]] && [[ "$force_detach" -eq 0 ]]; then
        # Source library modules
        source "${SCRIPT_DIR}/lib/agent-logger.sh"
        source "${SCRIPT_DIR}/lib/prompt-builder.sh"
        source "${SCRIPT_DIR}/lib/signal-detector.sh"
        source "${SCRIPT_DIR}/lib/context-monitor.sh"
        source "${SCRIPT_DIR}/lib/summary-generator.sh"

        # Mark session as running
        session_set_status "$session_name" "running"
        session_mark_started "$session_name"

        # Run the agent loop
        CONTINUE_MODE="$continue_mode"
        CURRENT_SESSION_NAME="$session_name"
        run_agent_loop "$PRD_FILE" "$PROTOCOL_FILE" "$PROJECT_DIR" "$TOKEN_LIMIT" "$MAX_LOOPS" "$CONTINUE_MODE" "$session_name"
    else
        # Interactive foreground call (or --detach flag): launch detached background process
        session_set_status "$session_name" "running"
        session_mark_started "$session_name"

        detach_start "$session_name" "${SCRIPT_DIR}/tarvos.sh" "$PROJECT_DIR"
        echo ""
        echo "View progress in the TUI:"
        echo "  tarvos tui"
        echo ""
        exit 0
    fi
}

# ──────────────────────────────────────────────────────────────
# tarvos continue — resume a stopped session from progress.md
# ──────────────────────────────────────────────────────────────
cmd_continue() {
    local session_name=""
    local force_detach=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_continue ;;
            --detach)
                force_detach=1
                shift
                ;;
            -*)
                echo "tarvos continue: unknown option: $1" >&2
                usage_continue
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos continue: unexpected argument: $1" >&2
                    usage_continue
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos continue: missing required argument <session-name>" >&2
        usage_continue
    fi

    # Validate dependencies
    if ! command -v claude &>/dev/null; then
        echo "tarvos continue: claude CLI not found in PATH." >&2
        exit 1
    fi

    # Source session manager, branch manager, worktree manager, and detach manager
    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/branch-manager.sh"
    source "${SCRIPT_DIR}/lib/worktree-manager.sh"
    source "${SCRIPT_DIR}/lib/detach-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos continue: session '${session_name}' not found. Run \`tarvos init <prd-path> --name ${session_name}\` first." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    # Only allow continuing stopped sessions
    case "$SESSION_STATUS" in
        running)
            echo "tarvos continue: session '${session_name}' is already running." >&2
            echo "  View it in the TUI: tarvos tui" >&2
            exit 1
            ;;
        initialized)
            echo "tarvos continue: session '${session_name}' has not been started yet." >&2
            echo "  Use 'tarvos begin ${session_name}' to start it." >&2
            exit 1
            ;;
        done)
            echo "tarvos continue: session '${session_name}' is already done. Use \`tarvos accept\` or \`tarvos reject\`." >&2
            exit 1
            ;;
        failed)
            echo "tarvos continue: session '${session_name}' has failed. Use \`tarvos reject\` to remove it." >&2
            exit 1
            ;;
    esac

    # Session is stopped — validate before handing off to background begin
    local PRD_FILE="$SESSION_PRD_FILE"

    # Validate PRD still exists
    if [[ ! -f "$PRD_FILE" ]]; then
        echo "tarvos continue: PRD file not found: $PRD_FILE" >&2
        echo "Re-run \`tarvos init <prd-path> --name ${session_name}\` with the correct path." >&2
        exit 1
    fi

    # Only check for a clean working directory when running interactively from the
    # main repo root.  Background workers cd into a worktree before exec'ing this
    # command, so the worktree may have in-progress agent changes — that's expected.
    local _is_background=0
    [[ ! -t 0 ]] && [[ "$force_detach" -eq 0 ]] && _is_background=1
    if [[ "$_is_background" -eq 0 ]]; then
        if ! branch_ensure_clean; then
            exit 1
        fi
    fi

    local WORKTREE_PATH=""

    # Use existing worktree or recreate it from the branch
    if worktree_exists "$session_name"; then
        WORKTREE_PATH="$SESSION_WORKTREE_PATH"
        if [[ -z "$WORKTREE_PATH" ]]; then
            WORKTREE_PATH="${TARVOS_PROJECT_ROOT:-$(pwd)}/.tarvos/worktrees/${session_name}"
        fi
        echo "tarvos: resuming worktree at '$(worktree_path "${session_name}")'"
    elif [[ -n "$SESSION_WORKTREE_PATH" ]]; then
        # Worktree .git file is gone but state.json records a path — could be
        # manually deleted or a branch+worktree that needs recreation.
        if [[ -n "$SESSION_BRANCH" ]]; then
            # Branch still exists — recreate the worktree
            local abs_wt_path
            if ! abs_wt_path=$(worktree_create "$session_name" "$SESSION_BRANCH"); then
                echo "tarvos: failed to recreate worktree for session '${session_name}'." >&2
                exit 1
            fi
            echo "tarvos: recreated worktree at '$(worktree_path "${session_name}")'"
            session_set_worktree_path "$session_name" "$abs_wt_path"
            WORKTREE_PATH="$abs_wt_path"
            session_load "$session_name"
        else
            # No branch — let the directory check below produce the right error
            WORKTREE_PATH="$SESSION_WORKTREE_PATH"
        fi
    elif [[ -n "$SESSION_BRANCH" ]]; then
        # No worktree path recorded, but branch exists — recreate from branch
        local abs_wt_path
        if ! abs_wt_path=$(worktree_create "$session_name" "$SESSION_BRANCH"); then
            echo "tarvos: failed to recreate worktree for session '${session_name}'." >&2
            exit 1
        fi
        echo "tarvos: recreated worktree at '$(worktree_path "${session_name}")'"
        session_set_worktree_path "$session_name" "$abs_wt_path"
        WORKTREE_PATH="$abs_wt_path"
        session_load "$session_name"
    fi

    # Protocol file (SKILL.md in the tarvos-skill folder)
    local PROTOCOL_FILE="${SCRIPT_DIR}/tarvos-skill/SKILL.md"
    if [[ ! -f "$PROTOCOL_FILE" ]]; then
        echo "tarvos continue: skill file not found: $PROTOCOL_FILE" >&2
        exit 1
    fi

    # Project directory: use the worktree for isolation — hard abort if missing
    local PROJECT_DIR
    if [[ -z "$WORKTREE_PATH" ]]; then
        error "No worktree path found for session '${session_name}'. Cannot continue."
        exit 1
    fi
    if [[ ! -d "$WORKTREE_PATH" ]]; then
        error "Worktree directory '${WORKTREE_PATH}' does not exist."
        error "It may have been manually deleted. To clean up: tarvos reject ${session_name}"
        exit 1
    fi
    PROJECT_DIR="$WORKTREE_PATH"

    local TOKEN_LIMIT="$SESSION_TOKEN_LIMIT"
    local MAX_LOOPS="$SESSION_MAX_LOOPS"

    # ── Background worker path ──────────────────────────────────
    # When stdin is not a tty AND --detach was NOT passed, we ARE the background
    # worker (launched by detach_start via nohup). Run the agent loop in-process.
    if [[ ! -t 0 ]] && [[ "$force_detach" -eq 0 ]]; then
        source "${SCRIPT_DIR}/lib/agent-logger.sh"
        source "${SCRIPT_DIR}/lib/prompt-builder.sh"
        source "${SCRIPT_DIR}/lib/signal-detector.sh"
        source "${SCRIPT_DIR}/lib/context-monitor.sh"
        source "${SCRIPT_DIR}/lib/summary-generator.sh"

        session_set_status "$session_name" "running"
        session_mark_started "$session_name"

        CONTINUE_MODE=1
        CURRENT_SESSION_NAME="$session_name"
        run_agent_loop "$PRD_FILE" "$PROTOCOL_FILE" "$PROJECT_DIR" "$TOKEN_LIMIT" "$MAX_LOOPS" "$CONTINUE_MODE" "$session_name"
        return
    fi

    # ── Foreground path (or --detach flag) ──────────────────────
    # Check that the session isn't already running in background
    if detach_is_running "$session_name"; then
        local existing_pid
        existing_pid=$(detach_get_pid "$session_name")
        echo "tarvos continue: session '${session_name}' is already running in the background (PID: ${existing_pid})." >&2
        exit 1
    fi

    detach_start "$session_name" "${SCRIPT_DIR}/tarvos.sh" "$PROJECT_DIR" "continue"
    echo ""
    echo "View progress in the TUI:"
    echo "  tarvos tui"
    echo ""
    exit 0
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
# tarvos tui — interactive session list TUI
# ──────────────────────────────────────────────────────────────
cmd_tui() {
    local initial_session=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_tui ;;
            view)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "tarvos tui view: missing session name" >&2
                    usage_tui
                fi
                initial_session="$1"
                shift
                ;;
            *)
                echo "tarvos tui: unexpected argument: $1" >&2
                usage_tui
                ;;
        esac
    done

    if [[ -n "$initial_session" ]]; then
        export TARVOS_TUI_INITIAL_SESSION="$initial_session"
    fi

    if [[ ! -x "$_TUI_BIN" ]]; then
        echo "Error: TUI binary not found. Re-run the tarvos installer:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/${TARVOS_REPO}/main/install.sh | bash" >&2
        echo "Or for development: cd tui && bun run build:darwin-arm64" >&2
        exit 1
    fi
    # Tell the TUI binary where tarvos.sh lives so it can invoke CLI
    # commands.  In compiled Bun binaries import.meta.dir is "/" which
    # breaks the relative path; this env var provides the real location.
    export TARVOS_SCRIPT_DIR="$SCRIPT_DIR"
    exec "$_TUI_BIN"
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
    source "${SCRIPT_DIR}/lib/worktree-manager.sh"

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

    # 3. Pre-flight conflict check (before touching the worktree)
    local _conflict_rc
    branch_check_conflicts "$source_branch" "$target_branch"
    _conflict_rc=$?
    if [[ $_conflict_rc -eq 1 ]]; then
        echo "" >&2
        echo "tarvos: conflict detected — this plan's changes conflict with your current branch." >&2
        echo "" >&2
        echo "This can happen when another plan was accepted first and modified the same files." >&2
        echo "Tarvos cannot auto-merge this safely. The session and branch are untouched." >&2
        echo "" >&2
        echo "To resolve manually:" >&2
        echo "  git checkout ${target_branch}" >&2
        echo "  git merge ${source_branch}" >&2
        echo "Then fix the conflicts and run: git merge --continue" >&2
        exit 1
    elif [[ $_conflict_rc -eq 2 ]]; then
        echo "tarvos: could not checkout target branch '${target_branch}' for conflict check." >&2
        exit 1
    fi

    # 4. Remove the worktree before merging (must be done before branch operations)
    if worktree_exists "$session_name"; then
        echo "  Removing worktree..."
        worktree_remove "$session_name" || true
    fi

    # 5. Attempt merge (branch_merge checks out target and merges source)
    local _merge_stderr_file
    _merge_stderr_file=$(mktemp)
    if ! branch_merge "$source_branch" "$target_branch" 2>"$_merge_stderr_file"; then
        local _merge_err
        _merge_err=$(cat "$_merge_stderr_file")
        rm -f "$_merge_stderr_file"
        if echo "$_merge_err" | grep -q "already checked out"; then
            echo "tarvos accept: The branch is checked out in another location." >&2
            echo "  Please 'cd' out of that directory and run accept again." >&2
        else
            # branch_merge already printed resolution instructions
            [[ -n "$_merge_err" ]] && echo "$_merge_err" >&2
        fi
        exit 1
    fi
    rm -f "$_merge_stderr_file"

    echo "  Merge successful."

    # 6. Archive session folder
    echo "  Archiving session..."
    session_archive "$session_name"

    # 7. Delete session branch
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
    source "${SCRIPT_DIR}/lib/worktree-manager.sh"

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

    # 3. Remove the worktree first (before deleting the branch)
    if worktree_exists "$session_name"; then
        echo "  Removing worktree..."
        worktree_remove "$session_name" || true
    fi

    # 4. Delete session branch (if exists)
    if [[ -n "$SESSION_BRANCH" ]]; then
        echo "  Deleting branch '${SESSION_BRANCH}'..."
        branch_delete "$SESSION_BRANCH" || true
    fi

    # 5. Delete session folder and remove from registry
    echo "  Removing session data..."
    session_delete "$session_name"

    echo ""
    echo "Session '${session_name}' rejected and removed."
}

# ──────────────────────────────────────────────────────────────
# tarvos forget — detach session without deleting its git branch
# ──────────────────────────────────────────────────────────────
cmd_forget() {
    local session_name=""
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_forget ;;
            --force)   force=1; shift ;;
            -*)
                echo "tarvos forget: unknown option: $1" >&2
                usage_forget
                ;;
            *)
                if [[ -z "$session_name" ]]; then
                    session_name="$1"
                else
                    echo "tarvos forget: unexpected argument: $1" >&2
                    usage_forget
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        echo "tarvos forget: missing required argument <session-name>" >&2
        usage_forget
    fi

    source "${SCRIPT_DIR}/lib/session-manager.sh"
    source "${SCRIPT_DIR}/lib/worktree-manager.sh"

    if ! session_exists "$session_name"; then
        echo "tarvos forget: session '${session_name}' not found." >&2
        exit 1
    fi

    session_load "$session_name" || exit 1

    # Refuse if session is running
    if [[ "$SESSION_STATUS" == "running" ]]; then
        echo "tarvos forget: session '${session_name}' is currently running." >&2
        echo "  Stop it first: tarvos stop ${session_name}" >&2
        exit 1
    fi

    # Only allowed for done or failed
    if [[ "$SESSION_STATUS" != "done" && "$SESSION_STATUS" != "failed" ]]; then
        echo "tarvos forget: session '${session_name}' has status '${SESSION_STATUS}'." >&2
        echo "  forget is only available for done or failed sessions." >&2
        exit 1
    fi

    # Confirmation prompt unless --force
    if (( ! force )); then
        local branch_display="${SESSION_BRANCH:-<none>}"
        echo "Forget session '${session_name}'?"
        echo ""
        echo "  This will remove the session from Tarvos. The git branch '${branch_display}' will"
        echo "  NOT be deleted — it stays in your repo for you to handle manually."
        echo "  Tarvos will no longer track this session."
        echo ""
        printf "  Type 'yes' to confirm: "
        local confirm
        IFS= read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Forget cancelled."
            exit 0
        fi
    fi

    echo "Forgetting session '${session_name}'..."

    # Remove the worktree if present
    if worktree_exists "$session_name"; then
        echo "  Removing worktree..."
        worktree_remove "$session_name" || true
    fi

    # Archive metadata (branch is NOT deleted)
    session_forget "$session_name"

    echo ""
    echo "Session forgotten. Branch '${SESSION_BRANCH}' is still in your repo."
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
# tarvos update — download and install a new Tarvos release
# ──────────────────────────────────────────────────────────────
cmd_update() {
    local REQUESTED_VERSION=""
    local FORCE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage_update ;;
            --version)
                if [[ -z "${2:-}" ]]; then
                    echo "tarvos update: --version requires a value" >&2
                    usage_update
                fi
                REQUESTED_VERSION="$2"
                shift 2
                ;;
            --version=*)
                REQUESTED_VERSION="${1#--version=}"
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            *)
                echo "tarvos update: unexpected argument: $1" >&2
                usage_update
                ;;
        esac
    done

    local BOLD='\033[1m' RESET='\033[0m' GREEN='\033[0;32m' YELLOW='\033[1;33m' DIM='\033[2m'

    # ── Determine target version ──────────────────────────────────────────────
    local TARGET_VERSION="$REQUESTED_VERSION"
    if [[ -z "$TARGET_VERSION" ]]; then
        echo -e "${DIM}Fetching latest Tarvos release from GitHub...${RESET}"
        if ! command -v curl &>/dev/null; then
            echo "Error: curl is required to update Tarvos." >&2
            exit 1
        fi
        local LATEST
        LATEST="$(curl -fsSL "https://api.github.com/repos/${TARVOS_REPO}/releases/latest" \
            | "$TARVOS_JQ" -r '.tag_name' 2>/dev/null || true)"
        if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then
            echo "Error: Could not determine the latest Tarvos release." >&2
            echo "Check your internet connection or specify a version with --version." >&2
            exit 1
        fi
        TARGET_VERSION="$LATEST"
    fi

    echo -e "Updating Tarvos to ${BOLD}${TARGET_VERSION}${RESET}..."

    # ── Platform detection ─────────────────────────────────────────────────────
    local OS ARCH TUI_PLATFORM JQ_PLATFORM
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m)"
    case "$OS/$ARCH" in
        darwin/arm64)   TUI_PLATFORM="darwin-arm64"; JQ_PLATFORM="macos-arm64"  ;;
        darwin/x86_64)  TUI_PLATFORM="darwin-x64";   JQ_PLATFORM="macos-amd64"  ;;
        linux/x86_64)   TUI_PLATFORM="linux-x64";    JQ_PLATFORM="linux-amd64"  ;;
        linux/aarch64)  TUI_PLATFORM="linux-arm64";  JQ_PLATFORM="linux-arm64"  ;;
        *)
            echo "Error: Unsupported platform: $OS/$ARCH" >&2
            exit 1
            ;;
    esac

    local TARVOS_BIN_DIR="${TARVOS_DATA_DIR}/bin"
    mkdir -p "$TARVOS_BIN_DIR"
    local GITHUB_RELEASES="https://github.com/${TARVOS_REPO}/releases/download/${TARGET_VERSION}"

    # ── Re-download jq only when --force or not present ───────────────────────
    local JQ_BIN="${TARVOS_BIN_DIR}/jq"
    if [[ "$FORCE" == true || ! -x "$JQ_BIN" ]]; then
        # Read the jq version from the installed VERSION file if available,
        # otherwise use a built-in fallback.
        local JQ_VERSION="jq-1.8.1"
        if [[ -f "${TARVOS_DATA_DIR}/VERSION" ]]; then
            local stored_jq
            stored_jq="$(grep '^JQ_VERSION=' "${TARVOS_DATA_DIR}/VERSION" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
            [[ -n "$stored_jq" ]] && JQ_VERSION="$stored_jq"
        fi
        echo -e "  Downloading ${DIM}jq (${JQ_VERSION})${RESET}..."
        curl -fsSL "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-${JQ_PLATFORM}" \
            -o "$JQ_BIN"
        chmod +x "$JQ_BIN"
        if [[ "$OS" == "darwin" ]]; then
            xattr -dr com.apple.quarantine "$JQ_BIN" 2>/dev/null || true
        fi
        echo -e "  ${GREEN}jq updated.${RESET}"
    else
        echo -e "  ${DIM}jq already installed — skipping (use --force to re-download).${RESET}"
    fi

    # ── Download fresh TUI binary ─────────────────────────────────────────────
    local TUI_BIN="${TARVOS_BIN_DIR}/tui"
    echo -e "  Downloading ${DIM}TUI binary (tui-${TUI_PLATFORM})${RESET}..."
    curl -fsSL "${GITHUB_RELEASES}/tui-${TUI_PLATFORM}" -o "$TUI_BIN"
    chmod +x "$TUI_BIN"
    if [[ "$OS" == "darwin" ]]; then
        xattr -dr com.apple.quarantine "$TUI_BIN" 2>/dev/null || true
    fi
    echo -e "  ${GREEN}TUI binary updated.${RESET}"

    # ── Download and extract new tarvos.sh + lib/ ─────────────────────────────
    local TARBALL_NAME="tarvos-${TARGET_VERSION}.tar.gz"
    echo -e "  Downloading ${DIM}${TARBALL_NAME}${RESET}..."
    local TARBALL_TMP
    TARBALL_TMP="$(mktemp "${TMPDIR:-/tmp}/tarvos-XXXXXX.tar.gz")"
    curl -fsSL "${GITHUB_RELEASES}/${TARBALL_NAME}" -o "$TARBALL_TMP"
    tar -xzf "$TARBALL_TMP" -C "$TARVOS_DATA_DIR" --strip-components=1
    rm -f "$TARBALL_TMP"
    chmod +x "${TARVOS_DATA_DIR}/tarvos.sh"
    echo -e "  ${GREEN}tarvos.sh + lib/ updated.${RESET}"

    # ── Update Claude skill ───────────────────────────────────────────────────
    local SKILLS_DIR="${HOME}/.claude/skills/tarvos-skill"
    mkdir -p "$SKILLS_DIR"
    if [[ -f "${TARVOS_DATA_DIR}/tarvos-skill/SKILL.md" ]]; then
        cp "${TARVOS_DATA_DIR}/tarvos-skill/SKILL.md" "${SKILLS_DIR}/SKILL.md"
        echo -e "  ${GREEN}Claude skill updated.${RESET}"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Tarvos ${TARGET_VERSION} installed successfully!${RESET}"
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

    # Emit loop_start event so TUI knows a new loop has begun
    local _ts
    _ts=$(date +%s)
    emit_tui_event "{\"type\":\"loop_start\",\"loop\":${loop_num},\"ts\":${_ts}}"

    # Emit launching status
    emit_tui_event "{\"type\":\"status\",\"content\":\"launching\",\"ts\":${_ts}}"

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
        log_warning "Context limit reached ($(get_total_tokens) tokens >= ${TOKEN_LIMIT})"

        local _ctx_ts
        _ctx_ts=$(date +%s)
        emit_tui_event "{\"type\":\"status\",\"content\":\"context_limit\",\"ts\":${_ctx_ts}}"

        kill_claude_process "$CLAUDE_PID"
        CLAUDE_PID=""

        local continuation_prompt
        continuation_prompt=$(build_context_limit_prompt "${PROGRESS_FILE:-}")
        run_continuation_session "$continuation_prompt" "$raw_log" "$text_output"
    else
        wait "$CLAUDE_PID" 2>/dev/null
        local claude_exit=$?
        CLAUDE_PID=""

        if [[ $claude_exit -ne 0 ]]; then
            if [[ -s "$stderr_log" ]]; then
                log_error "Claude exited with code ${claude_exit}: $(head -c 300 "$stderr_log" | tr '\n' ' ' | sed "s|$HOME|~|g")"
            else
                log_error "Claude exited with code ${claude_exit} (no stderr)"
            fi
        elif [[ ! -s "$text_output" ]]; then
            log_warning "Claude produced no text output (exit code 0)"
            if [[ -s "$stderr_log" ]]; then
                log_warning "Stderr: $(head -c 300 "$stderr_log" | tr '\n' ' ' | sed "s|$HOME|~|g")"
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

    cd "$PROJECT_DIR" || { error "Failed to cd into project dir: ${PROJECT_DIR}"; exit 1; }
    # Safety: ensure we are NOT running in the main repo root
    local _main_root
    _main_root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "$_main_root" ]] && [[ "$(pwd)" == "$_main_root" ]]; then
        error "SAFETY ABORT: agent loop would run in the main repo root. Refusing to proceed."
        exit 1
    fi

    # Determine the progress.md location:
    # If a session is active, use session-local progress.md; otherwise fall back to project root.
    # Use SESSIONS_DIR (which is absolute when TARVOS_PROJECT_ROOT is set) so this works even
    # after cd into a worktree.
    local PROGRESS_FILE
    if [[ -n "$session_name" ]] && [[ -d "${SESSIONS_DIR}/${session_name}" ]]; then
        PROGRESS_FILE="${SESSIONS_DIR}/${session_name}/progress.md"
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

    # Initialize logging: use session logs folder if session is active.
    # Use SESSIONS_DIR (absolute) to avoid relative-path issues after cd into worktree.
    local log_base_dir
    if [[ -n "$session_name" ]] && [[ -d "${SESSIONS_DIR}/${session_name}" ]]; then
        log_base_dir="${SESSIONS_DIR}/${session_name}"
    else
        log_base_dir="$PROJECT_DIR"
    fi
    init_logging "$log_base_dir"

    # Persist log_dir into state.json so the TUI can find the correct events file
    if [[ -n "$session_name" ]]; then
        session_set_log_dir "$session_name" "$LOG_DIR"
    fi

    # Signal traps
    trap 'shutdown 130' INT
    trap 'shutdown 143' TERM

    local start_time
    start_time=$(date +%s)

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

            # Emit running status after successful loop iteration
            local _loop_ts
            _loop_ts=$(date +%s)
            emit_tui_event "{\"type\":\"status\",\"content\":\"running\",\"ts\":${_loop_ts}}"

            case "$DETECTED_SIGNAL" in
                ALL_PHASES_COMPLETE)
                    log_success "All phases complete!"
                    final_signal="$DETECTED_SIGNAL"
                    if [[ -n "$session_name" ]]; then
                        session_set_status "$session_name" "done"
                        session_set_final_signal "$session_name" "$final_signal"
                    fi
                    # Emit done status
                    local _done_ts
                    _done_ts=$(date +%s)
                    emit_tui_event "{\"type\":\"status\",\"content\":\"done\",\"ts\":${_done_ts}}"
                    # 1. Generate summary while worktree still exists
                    if [[ -n "$session_name" ]]; then
                        log_info "Generating completion summary..."
                        local _gen_ts
                        _gen_ts=$(date +%s)
                        emit_tui_event "{\"type\":\"status\",\"content\":\"generating_summary\",\"ts\":${_gen_ts}}"
                        if generate_summary "$session_name" "$PRD_FILE" "${PROGRESS_FILE:-}" "$LOG_DIR" "${WORKTREE_PATH:-}"; then
                            log_success "Summary saved to .tarvos/sessions/${session_name}/summary.md"
                            local _ready_ts
                            _ready_ts=$(date +%s)
                            emit_tui_event "{\"type\":\"status\",\"content\":\"summary_ready\",\"ts\":${_ready_ts}}"
                        else
                            log_warning "Summary generation failed (summary unavailable)"
                            local _fail_ts
                            _fail_ts=$(date +%s)
                            emit_tui_event "{\"type\":\"status\",\"content\":\"summary_failed\",\"ts\":${_fail_ts}}"
                        fi
                    fi
                    # 2. Remove worktree AFTER summary so branch is freely accessible
                    if [[ -n "$session_name" ]] && worktree_exists "$session_name"; then
                        log_info "Releasing worktree (branch remains for review)..."
                        worktree_remove "$session_name" || true
                    fi
                    break
                    ;;
                PHASE_COMPLETE)
                    log_success "Phase complete, starting next iteration..."
                    ensure_progress_file
                    ;;
                PHASE_IN_PROGRESS)
                    log_info "Phase in progress, continuing in next iteration..."
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
        # Release worktree for stopped/failed so branch is freely accessible
        if worktree_exists "$session_name"; then
            log_info "Releasing worktree (branch remains for review)..."
            worktree_remove "$session_name" || true
        fi
    fi

    log_final_summary "$loop_num" "$final_signal" "$start_time" "$session_name"

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
        return 0
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        init)     cmd_init "$@" ;;
        begin)    cmd_begin "$@" ;;
        continue) cmd_continue "$@" ;;
        attach)   cmd_attach "$@" ;;
        stop)     cmd_stop "$@" ;;
        tui)      cmd_tui "$@" ;;
        accept)   cmd_accept "$@" ;;
        reject)   cmd_reject "$@" ;;
        forget)   cmd_forget "$@" ;;
        migrate)  cmd_migrate "$@" ;;
        update)   cmd_update "$@" ;;
        -h|--help) usage_root ;;
        *)
            echo "tarvos: unknown command: ${cmd}" >&2
            echo "Run \`tarvos --help\` for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
