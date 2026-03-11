#!/usr/bin/env bash
# session-manager.sh - Session CRUD and state management for Tarvos async ecosystem

# ──────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────
SESSIONS_DIR=".tarvos/sessions"
REGISTRY_FILE=".tarvos/sessions.json"
ARCHIVE_DIR=".tarvos/archive"

# Globals loaded by session_load()
SESSION_NAME=""
SESSION_STATUS=""
SESSION_PRD_FILE=""
SESSION_TOKEN_LIMIT=""
SESSION_MAX_LOOPS=""
SESSION_BRANCH=""
SESSION_ORIGINAL_BRANCH=""
SESSION_WORKTREE_PATH=""
SESSION_CREATED_AT=""
SESSION_STARTED_AT=""
SESSION_LAST_ACTIVITY=""
SESSION_LOOP_COUNT=""
SESSION_FINAL_SIGNAL=""

# ──────────────────────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────────────────────

# Validate session name: alphanumeric + hyphens only
# Args: $1 = name
# Returns 0 if valid, 1 if not
session_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "tarvos: session name cannot be empty" >&2
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        echo "tarvos: invalid session name '${name}' — use alphanumeric characters and hyphens only (must start with alphanumeric)" >&2
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────
# Registry helpers
# ──────────────────────────────────────────────────────────────

# Initialize registry file if it doesn't exist
_registry_ensure() {
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo '{"version":1,"sessions":{}}' > "$REGISTRY_FILE"
    fi
}

# Update a session entry in the registry
# Args: $1 = name, $2 = status, $3 = branch, $4 = original_branch, $5 = last_activity
registry_update() {
    local name="$1"
    local status="$2"
    local branch="${3:-}"
    local original_branch="${4:-}"
    local last_activity="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

    _registry_ensure

    local tmp
    tmp=$(mktemp)
    jq --arg name "$name" \
       --arg status "$status" \
       --arg branch "$branch" \
       --arg original_branch "$original_branch" \
       --arg last_activity "$last_activity" \
       '.sessions[$name] = {
           "status": $status,
           "branch": $branch,
           "original_branch": $original_branch,
           "last_activity": $last_activity
       }' "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Remove a session entry from the registry
# Args: $1 = name
registry_remove() {
    local name="$1"
    _registry_ensure

    local tmp
    tmp=$(mktemp)
    jq --arg name "$name" 'del(.sessions[$name])' "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# ──────────────────────────────────────────────────────────────
# Session folder path helpers
# ──────────────────────────────────────────────────────────────
session_dir()          { echo "${SESSIONS_DIR}/$1"; }
session_state_file()   { echo "${SESSIONS_DIR}/$1/state.json"; }
session_prd_file()     { echo "${SESSIONS_DIR}/$1/prd.md"; }
session_progress_file(){ echo "${SESSIONS_DIR}/$1/progress.md"; }
session_pid_file()     { echo "${SESSIONS_DIR}/$1/pid"; }
session_output_log()   { echo "${SESSIONS_DIR}/$1/output.log"; }
session_logs_dir()     { echo "${SESSIONS_DIR}/$1/logs"; }

# ──────────────────────────────────────────────────────────────
# Core CRUD
# ──────────────────────────────────────────────────────────────

# Create a new session folder and state
# Args: $1 = name, $2 = prd_path (absolute), $3 = token_limit, $4 = max_loops
# Returns 0 on success, 1 on failure
session_init() {
    local name="$1"
    local prd_path="$2"
    local token_limit="$3"
    local max_loops="$4"

    session_validate_name "$name" || return 1

    if session_exists "$name"; then
        echo "tarvos: session '${name}' already exists. Use a different name or reject the existing session first." >&2
        return 1
    fi

    local session_folder
    session_folder=$(session_dir "$name")

    mkdir -p "$session_folder"
    mkdir -p "${session_folder}/logs"

    # Copy PRD into session folder
    cp "$prd_path" "$(session_prd_file "$name")"

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Write state.json
    jq -n \
        --arg name "$name" \
        --arg prd_file "$prd_path" \
        --arg token_limit "$token_limit" \
        --arg max_loops "$max_loops" \
        --arg created_at "$now" \
        --arg last_activity "$now" \
        '{
            "name": $name,
            "status": "initialized",
            "prd_file": $prd_file,
            "token_limit": ($token_limit | tonumber),
            "max_loops": ($max_loops | tonumber),
            "branch": "",
            "original_branch": "",
            "worktree_path": "",
            "log_dir": "",
            "created_at": $created_at,
            "started_at": "",
            "last_activity": $last_activity,
            "loop_count": 0,
            "final_signal": null
        }' > "$(session_state_file "$name")"

    registry_update "$name" "initialized" "" "" "$now"

    return 0
}

# Load session state into global SESSION_* variables
# Args: $1 = name
# Returns 0 on success, 1 if not found
session_load() {
    local name="$1"

    if ! session_exists "$name"; then
        echo "tarvos: session '${name}' not found." >&2
        return 1
    fi

    local state_file
    state_file=$(session_state_file "$name")

    SESSION_NAME=$(jq -r '.name' "$state_file")
    SESSION_STATUS=$(jq -r '.status' "$state_file")
    SESSION_PRD_FILE=$(jq -r '.prd_file' "$state_file")
    SESSION_TOKEN_LIMIT=$(jq -r '.token_limit' "$state_file")
    SESSION_MAX_LOOPS=$(jq -r '.max_loops' "$state_file")
    SESSION_BRANCH=$(jq -r '.branch' "$state_file")
    SESSION_ORIGINAL_BRANCH=$(jq -r '.original_branch' "$state_file")
    SESSION_WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$state_file")
    SESSION_CREATED_AT=$(jq -r '.created_at' "$state_file")
    SESSION_STARTED_AT=$(jq -r '.started_at' "$state_file")
    SESSION_LAST_ACTIVITY=$(jq -r '.last_activity' "$state_file")
    SESSION_LOOP_COUNT=$(jq -r '.loop_count' "$state_file")
    SESSION_FINAL_SIGNAL=$(jq -r '.final_signal // ""' "$state_file")

    return 0
}

# Update session status and registry
# Args: $1 = name, $2 = new status
session_set_status() {
    local name="$1"
    local status="$2"
    local state_file
    state_file=$(session_state_file "$name")

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$(mktemp)
    jq --arg status "$status" --arg now "$now" \
        '.status = $status | .last_activity = $now' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"

    # Also update registry
    local branch original_branch
    branch=$(jq -r '.branch // ""' "$state_file")
    original_branch=$(jq -r '.original_branch // ""' "$state_file")
    registry_update "$name" "$status" "$branch" "$original_branch" "$now"
}

# Update any field in session state (key=value pairs)
# Args: $1 = name, then alternating key value pairs
session_update() {
    local name="$1"
    shift
    local state_file
    state_file=$(session_state_file "$name")

    local tmp
    tmp=$(mktemp)
    local jq_filter='.'
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2
        jq_filter+=" | .\"${key}\" = \"${val}\""
    done
    jq_filter+=" | .last_activity = \"${now}\""

    jq "$jq_filter" "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Check if a session exists
# Args: $1 = name
# Returns 0 if exists, 1 if not
session_exists() {
    local name="$1"
    [[ -f "$(session_state_file "$name")" ]]
}

# List all session names
# Outputs one name per line
session_list() {
    if [[ ! -d "$SESSIONS_DIR" ]]; then
        return 0
    fi

    local name
    for state_file in "${SESSIONS_DIR}"/*/state.json; do
        [[ -f "$state_file" ]] || continue
        name=$(jq -r '.name' "$state_file" 2>/dev/null)
        [[ -n "$name" ]] && echo "$name"
    done
}

# Delete a session folder
# Args: $1 = name
session_delete() {
    local name="$1"
    local session_folder
    session_folder=$(session_dir "$name")

    if [[ -d "$session_folder" ]]; then
        rm -rf "$session_folder"
    fi
    registry_remove "$name"
}

# Archive a session (move to .tarvos/archive/<name>-<timestamp>/)
# Args: $1 = name
session_archive() {
    local name="$1"
    local session_folder
    session_folder=$(session_dir "$name")

    if [[ ! -d "$session_folder" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local archive_dest="${ARCHIVE_DIR}/${name}-${timestamp}"

    mkdir -p "$ARCHIVE_DIR"
    mv "$session_folder" "$archive_dest"
    registry_remove "$name"
}

# Update loop count in state
# Args: $1 = name, $2 = loop_count
session_set_loop_count() {
    local name="$1"
    local count="$2"
    local state_file
    state_file=$(session_state_file "$name")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$(mktemp)
    jq --argjson count "$count" --arg now "$now" \
        '.loop_count = $count | .last_activity = $now' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Set the final signal in state
# Args: $1 = name, $2 = final_signal
session_set_final_signal() {
    local name="$1"
    local signal="$2"
    local state_file
    state_file=$(session_state_file "$name")

    local tmp
    tmp=$(mktemp)
    jq --arg signal "$signal" '.final_signal = $signal' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Update branch and original_branch in session state and registry
# Args: $1 = name, $2 = branch, $3 = original_branch
session_set_branch() {
    local name="$1"
    local branch="$2"
    local original_branch="$3"
    local state_file
    state_file=$(session_state_file "$name")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$(mktemp)
    jq --arg branch "$branch" \
       --arg original_branch "$original_branch" \
       --arg now "$now" \
       '.branch = $branch | .original_branch = $original_branch | .last_activity = $now' \
       "$state_file" > "$tmp" && mv "$tmp" "$state_file"

    local status
    status=$(jq -r '.status' "$state_file")
    registry_update "$name" "$status" "$branch" "$original_branch" "$now"
}

# Update worktree_path in session state
# Args: $1 = name, $2 = worktree_path (absolute path)
session_set_worktree_path() {
    local name="$1"
    local wt_path="$2"
    local state_file
    state_file=$(session_state_file "$name")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$(mktemp)
    jq --arg wt_path "$wt_path" --arg now "$now" \
        '.worktree_path = $wt_path | .last_activity = $now' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Mark session as started (set started_at timestamp)
# Args: $1 = name
session_mark_started() {
    local name="$1"
    local state_file
    state_file=$(session_state_file "$name")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$(mktemp)
    jq --arg now "$now" '.started_at = $now | .last_activity = $now' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Update log_dir in session state (called after init_logging sets LOG_DIR)
# Args: $1 = name, $2 = log_dir (absolute path to current run's log directory)
session_set_log_dir() {
    local name="$1"
    local log_dir="$2"
    local state_file
    state_file="$(session_state_file "$name")"
    local tmp="${state_file}.tmp.$$"
    jq --arg v "$log_dir" '.log_dir = $v | .last_activity = now | todate' \
        "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}
