#!/usr/bin/env bash
# summary-generator.sh - Completion summary generator for Tarvos sessions
# Called when ALL_PHASES_COMPLETE is detected. Uses `claude --continue` from
# the worktree directory to resume the last Claude Code session and produce
# a structured markdown summary written to summary.md.

# ──────────────────────────────────────────────────────────────
# generate_summary
# Generate a human-readable summary of what the PRD built.
# Uses `claude --continue` from the worktree so Claude has full
# context of what it actually built.
#
# Args:
#   $1 = session_name
#   $2 = prd_file (path to the PRD markdown)
#   $3 = progress_file (path to the final progress.md)
#   $4 = log_dir (path to the session's log directory, for dashboard.log)
#   $5 = worktree_path (NEW: worktree dir to run --continue from)
#
# Returns: 0 on success, 1 if claude invocation fails.
# ──────────────────────────────────────────────────────────────
generate_summary() {
    local session_name="$1"
    local prd_file="$2"
    local progress_file="$3"
    local log_dir="$4"
    local worktree_path="$5"   # NEW: worktree dir to run --continue from

    local session_dir=".tarvos/sessions/${session_name}"
    local summary_file="${session_dir}/summary.md"
    local dashboard_log="${log_dir}/dashboard.log"

    # Validate inputs
    if [[ ! -f "$prd_file" ]]; then
        echo "generate_summary: PRD file not found: ${prd_file}" >&2
        return 1
    fi

    # Validate worktree path
    if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
        echo "generate_summary: worktree path missing or gone: ${worktree_path}" >&2
        return 1
    fi

    # Build the summary prompt
    local prompt
    prompt=$(cat <<PROMPT
You are the same coding agent that just completed all phases of the PRD for session "${session_name}".

Write a compact, structured markdown summary of what you built during this session.
Target length: half a page to one page of markdown.

Include:
- **What was built**: key features, components, functions added or changed
- **Files changed**: list each file with a one-line description of the change
- **How to use**: brief usage instructions or code examples if relevant
- **Notes**: any caveats, known limitations, or follow-up items

Start directly with the content — no preamble.
Format with markdown headers, bullet points, and code blocks where appropriate.
PROMPT
)

    # Initialize summary file
    mkdir -p "$session_dir"
    > "$summary_file"

    # TODO: Make coding-agent agnostic — currently Claude Code specific (uses `claude --continue`)
    local summary_output
    if ! summary_output=$(
        cd "$worktree_path" && \
        claude --continue \
            -p "$prompt" \
            --dangerously-skip-permissions \
            --output-format text \
            2>/dev/null
    ); then
        echo "generate_summary: claude --continue invocation failed for session '${session_name}'" >&2
        return 1
    fi

    if [[ -z "$summary_output" ]]; then
        echo "generate_summary: claude returned empty output" >&2
        return 1
    fi

    # Write to summary.md
    echo "$summary_output" > "$summary_file"

    # Append to dashboard.log with [SUMMARY] prefix
    if [[ -f "$dashboard_log" ]]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        {
            echo ""
            echo "${timestamp} | [SUMMARY] Session: ${session_name}"
            while IFS= read -r line; do
                echo "${timestamp} | [SUMMARY] ${line}"
            done <<< "$summary_output"
        } >> "$dashboard_log"
    fi

    return 0
}
