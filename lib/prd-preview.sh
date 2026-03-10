#!/usr/bin/env bash
# prd-preview.sh - Calls a non-agentic Claude instance to analyse the PRD
# and produce a structured preview for `tarvos init`.
#
# Output schema (plain text, one field per line):
#
#   VALIDITY: VALID | WARN | INVALID
#   REASON: <one line — only present when WARN or INVALID>
#   TITLE: <project title inferred from the document>
#   TYPE: <sprint | phase | milestone | task-list | freeform>
#   UNITS:
#     1. <unit title>
#     2. <unit title>
#     ...
#   NOTES: <optional 1-2 line concern>
#
# The shell parser reads this with simple line-by-line matching.

# ──────────────────────────────────────────────────────────────
# Build the preview prompt
# ──────────────────────────────────────────────────────────────
_build_preview_prompt() {
    local prd_content="$1"

    cat <<PROMPT
You are a planning document analyser. A user is about to run an AI coding orchestrator against the document below. Your job is to read it and produce a short structured preview so the user can confirm it makes sense before proceeding.

Respond with ONLY the structured output below — no prose, no explanation, no markdown fences. Follow the schema exactly.

─── OUTPUT SCHEMA ───────────────────────────────────────────────
VALIDITY: <VALID | WARN | INVALID>
REASON: <one sentence — ONLY include this line when VALIDITY is WARN or INVALID>
TITLE: <short project title inferred from the document>
TYPE: <one of: phase | sprint | milestone | task-list | freeform>
UNITS:
  1. <unit title>
  2. <unit title>
  (list every top-level work unit; max 20)
NOTES: <one or two sentences flagging anything genuinely concerning — omit this line entirely if nothing worth flagging>
─────────────────────────────────────────────────────────────────

Validity rules:
- VALID   — document is a coherent plan with identifiable units of work
- WARN    — document is usable but has a notable issue (e.g. vague scope, missing acceptance criteria, only one unit, very short)
- INVALID — document is not a workable plan (e.g. empty, unrelated content, pure notes with no actionable structure)

Type rules:
- phase      — units are called "Phase N" or similar sequential phases
- sprint      — units are sprints, iterations, or time-boxes
- milestone  — units are milestones or deliverables
- task-list  — a flat list of tasks with no grouping
- freeform   — structured but doesn't fit the above

─── EXAMPLE OUTPUT ──────────────────────────────────────────────
VALIDITY: WARN
REASON: No acceptance criteria or test requirements defined for any unit.
TITLE: E-commerce Checkout Redesign
TYPE: phase
UNITS:
  1. Phase 1: Auth & User Accounts
  2. Phase 2: Product Catalogue
  3. Phase 3: Cart & Checkout Flow
  4. Phase 4: Payment Integration
  5. Phase 5: Admin Dashboard
NOTES: Phase 4 references a third-party payment SDK but doesn't specify which one — the agent may need to make an assumption.
─────────────────────────────────────────────────────────────────

─── DOCUMENT TO ANALYSE ─────────────────────────────────────────
${prd_content}
─────────────────────────────────────────────────────────────────
PROMPT
}

# ──────────────────────────────────────────────────────────────
# Run the preview agent (non-agentic single LLM call)
# Args: $1 = PRD file path
# Outputs raw schema text to stdout
# Returns: 0 on success, 1 on failure
# ──────────────────────────────────────────────────────────────
run_prd_preview() {
    local prd_file="$1"

    local prd_content
    prd_content=$(cat "$prd_file")

    local prompt
    prompt=$(_build_preview_prompt "$prd_content")

    # Non-agentic call: --output-format text, no tools, no permissions needed
    local output
    output=$(claude -p "$prompt" --output-format text 2>/dev/null)

    if [[ -z "$output" ]]; then
        return 1
    fi

    echo "$output"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Parse the schema output and display a formatted preview
# Also sets globals used by cmd_init:
#   PREVIEW_VALIDITY  (VALID | WARN | INVALID)
#   PREVIEW_TITLE
#   PREVIEW_TYPE
#   PREVIEW_UNITS     (newline-separated numbered list)
#   PREVIEW_REASON
#   PREVIEW_NOTES
# Args: $1 = raw schema text
# ──────────────────────────────────────────────────────────────
parse_preview_output() {
    local raw="$1"

    PREVIEW_VALIDITY="VALID"
    PREVIEW_TITLE=""
    PREVIEW_TYPE=""
    PREVIEW_REASON=""
    PREVIEW_UNITS=""
    PREVIEW_NOTES=""

    local in_units=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^VALIDITY:[[:space:]]*(.*) ]]; then
            PREVIEW_VALIDITY="${BASH_REMATCH[1]}"
            in_units=0
        elif [[ "$line" =~ ^REASON:[[:space:]]*(.*) ]]; then
            PREVIEW_REASON="${BASH_REMATCH[1]}"
            in_units=0
        elif [[ "$line" =~ ^TITLE:[[:space:]]*(.*) ]]; then
            PREVIEW_TITLE="${BASH_REMATCH[1]}"
            in_units=0
        elif [[ "$line" =~ ^TYPE:[[:space:]]*(.*) ]]; then
            PREVIEW_TYPE="${BASH_REMATCH[1]}"
            in_units=0
        elif [[ "$line" =~ ^UNITS: ]]; then
            in_units=1
        elif [[ "$line" =~ ^NOTES:[[:space:]]*(.*) ]]; then
            PREVIEW_NOTES="${BASH_REMATCH[1]}"
            in_units=0
        elif [[ "$in_units" -eq 1 ]]; then
            # Collect indented unit lines (e.g. "  1. Phase 1: ...")
            if [[ "$line" =~ ^[[:space:]]+[0-9]+\.[[:space:]]*(.*) ]]; then
                if [[ -n "$PREVIEW_UNITS" ]]; then
                    PREVIEW_UNITS+=$'\n'
                fi
                PREVIEW_UNITS+="    ${line#"${line%%[![:space:]]*}"}"
            elif [[ -n "$line" && ! "$line" =~ ^[[:space:]]*$ ]]; then
                in_units=0
            fi
        fi
    done <<< "$raw"
}

# ──────────────────────────────────────────────────────────────
# Display the formatted preview to the terminal
# Call parse_preview_output first.
# Args: $1 = prd_file, $2 = project_dir, $3 = token_limit, $4 = max_loops
# ──────────────────────────────────────────────────────────────
display_preview() {
    local prd_file="$1"
    local project_dir="$2"
    local token_limit="$3"
    local max_loops="$4"

    # Colors (inline — this file may be sourced before log-manager)
    local BOLD='\033[1m'
    local RESET='\033[0m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local RED='\033[0;31m'
    local DIM='\033[2m'
    local CYAN='\033[0;36m'

    local validity_color validity_label
    case "$PREVIEW_VALIDITY" in
        VALID)   validity_color="$GREEN"  ; validity_label="valid" ;;
        WARN)    validity_color="$YELLOW" ; validity_label="valid with warnings" ;;
        INVALID) validity_color="$RED"    ; validity_label="invalid" ;;
        *)       validity_color="$DIM"    ; validity_label="unknown" ;;
    esac

    echo ""
    echo -e "  ${BOLD}Tarvos — AI Coding Agent Orchestrator${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
    printf "  ${BOLD}%-14s${RESET}%s\n" "PRD:" "$prd_file"
    printf "  ${BOLD}%-14s${RESET}%s\n" "Project:" "$project_dir"
    printf "  ${BOLD}%-14s${RESET}" "Token limit:"
    printf "%'.0f per agent\n" "$token_limit" 2>/dev/null || printf "%s per agent\n" "$token_limit"
    printf "  ${BOLD}%-14s${RESET}%s\n" "Max loops:" "$max_loops"

    echo ""
    printf "  ${BOLD}%-14s${RESET}${validity_color}%s${RESET}\n" "PRD status:" "$validity_label"

    if [[ -n "$PREVIEW_TITLE" ]]; then
        printf "  ${BOLD}%-14s${RESET}%s\n" "Title:" "$PREVIEW_TITLE"
    fi
    if [[ -n "$PREVIEW_TYPE" ]]; then
        printf "  ${BOLD}%-14s${RESET}%s\n" "Structure:" "$PREVIEW_TYPE"
    fi

    if [[ -n "$PREVIEW_REASON" ]]; then
        echo ""
        echo -e "  ${validity_color}${BOLD}Warning:${RESET} ${validity_color}${PREVIEW_REASON}${RESET}"
    fi

    if [[ -n "$PREVIEW_UNITS" ]]; then
        echo ""
        echo -e "  ${BOLD}Work units detected:${RESET}"
        while IFS= read -r unit_line; do
            echo -e "  ${unit_line}"
        done <<< "$PREVIEW_UNITS"
    fi

    if [[ -n "$PREVIEW_NOTES" ]]; then
        echo ""
        echo -e "  ${DIM}Note: ${PREVIEW_NOTES}${RESET}"
    fi

    echo ""
    echo -e "  ${DIM}Config written to: .tarvos/config${RESET}"
    echo -e "  ${DIM}Tip: add .tarvos/ to your .gitignore${RESET}"
    echo ""

    if [[ "$PREVIEW_VALIDITY" == "INVALID" ]]; then
        echo -e "  ${RED}${BOLD}Ready (but review your PRD before proceeding).${RESET}"
    elif [[ "$PREVIEW_VALIDITY" == "WARN" ]]; then
        echo -e "  ${YELLOW}${BOLD}Ready (with warnings).${RESET} Run \`tarvos begin\` to start."
    else
        echo -e "  ${GREEN}${BOLD}Ready.${RESET} Run \`tarvos begin\` to start."
    fi
    echo ""
}
