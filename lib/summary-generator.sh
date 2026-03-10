#!/usr/bin/env bash
# summary-generator.sh - Completion summary generator for Tarvos sessions
# Phase 4: Called when ALL_PHASES_COMPLETE is detected. Invokes Claude non-agentically
# to produce a ≤30-line developer-facing summary, streamed to summary.md.

# ──────────────────────────────────────────────────────────────
# generate_summary
# Generate a human-readable summary of what the PRD built.
# Calls `claude -p <prompt> --output-format text` non-agentically.
# Output is streamed line-by-line to <session_dir>/summary.md and
# also appended to the dashboard.log with a [SUMMARY] prefix.
#
# Args:
#   $1 = session_name
#   $2 = prd_file (path to the PRD markdown)
#   $3 = progress_file (path to the final progress.md)
#   $4 = log_dir (path to the session's log directory, for dashboard.log)
#
# Returns: 0 on success, 1 if claude invocation fails.
# ──────────────────────────────────────────────────────────────
generate_summary() {
    local session_name="$1"
    local prd_file="$2"
    local progress_file="$3"
    local log_dir="$4"

    local session_dir=".tarvos/sessions/${session_name}"
    local summary_file="${session_dir}/summary.md"
    local dashboard_log="${log_dir}/dashboard.log"

    # Validate inputs
    if [[ ! -f "$prd_file" ]]; then
        echo "generate_summary: PRD file not found: ${prd_file}" >&2
        return 1
    fi

    # Read PRD content
    local prd_content
    prd_content=$(cat "$prd_file" 2>/dev/null || echo "")

    # Read progress.md content (may not exist on very first completion)
    local progress_content=""
    if [[ -f "$progress_file" ]]; then
        progress_content=$(cat "$progress_file" 2>/dev/null || echo "")
    fi

    # Build the summary prompt
    local prompt
    prompt=$(cat <<PROMPT
You are a developer-focused summary writer for an AI coding orchestration tool called Tarvos.

A session named "${session_name}" just completed all phases of this PRD:

--- PRD START ---
${prd_content}
--- PRD END ---

--- PROGRESS REPORT (final state) ---
${progress_content}
--- PROGRESS REPORT END ---

Write a concise developer-facing summary (30 lines maximum) covering:
1. What was built (features, functionality, key components)
2. Which files were changed or created (list them concisely)
3. How to use the new feature or fix (code examples if helpful, briefly)
4. Any follow-up notes or caveats

Format it as plain text with section headers like:
  What was built:
  › item

  Files changed:
  › file: description

  How to use:
  › usage

  Notes:
  › note

Be specific and actionable. Skip preamble — start directly with content.
PROMPT
)

    # Initialize summary file
    mkdir -p "$session_dir"
    > "$summary_file"

    # Stream output from claude to summary.md line by line
    local summary_output
    if ! summary_output=$(claude -p "$prompt" --output-format text 2>/dev/null); then
        echo "generate_summary: claude invocation failed for session '${session_name}'" >&2
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
