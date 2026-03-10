#!/usr/bin/env bash
# worktree-manager.sh - Git worktree isolation for Tarvos sessions
# Phase 4: Each session runs in .tarvos/worktrees/<session-name>/ on its own branch.

# ──────────────────────────────────────────────────────────────
# worktree_path
# Echo the relative path for a session's worktree.
# Args: $1 = session_name
# ──────────────────────────────────────────────────────────────
worktree_path() {
    local session_name="$1"
    echo ".tarvos/worktrees/${session_name}"
}

# ──────────────────────────────────────────────────────────────
# worktree_exists
# Check if a worktree directory exists and is a valid git worktree.
# Args: $1 = session_name
# Returns 0 if exists, 1 if not.
# ──────────────────────────────────────────────────────────────
worktree_exists() {
    local session_name="$1"
    local wt_path
    wt_path=$(worktree_path "$session_name")
    # A valid worktree has a .git file (not directory) pointing to the parent repo
    [[ -f "${wt_path}/.git" ]]
}

# ──────────────────────────────────────────────────────────────
# worktree_create
# Create a new git worktree at .tarvos/worktrees/<session_name>/
# on the given branch. The branch must already exist in git.
# Args: $1 = session_name, $2 = branch_name
# Outputs: the absolute path to the worktree
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────
worktree_create() {
    local session_name="$1"
    local branch_name="$2"

    local wt_path
    wt_path=$(worktree_path "$session_name")

    # Ensure parent directory exists
    mkdir -p ".tarvos/worktrees"

    # If worktree already exists, just return the path
    if worktree_exists "$session_name"; then
        echo "$(pwd)/${wt_path}"
        return 0
    fi

    # Create the worktree
    if ! git worktree add "$wt_path" "$branch_name" 2>/dev/null; then
        echo "tarvos: failed to create worktree at '${wt_path}' on branch '${branch_name}'." >&2
        return 1
    fi

    echo "$(pwd)/${wt_path}"
    return 0
}

# ──────────────────────────────────────────────────────────────
# worktree_remove
# Remove a session's worktree and prune stale git worktree entries.
# Args: $1 = session_name
# Returns 0 on success (including if already gone), 1 on failure.
# ──────────────────────────────────────────────────────────────
worktree_remove() {
    local session_name="$1"
    local wt_path
    wt_path=$(worktree_path "$session_name")

    # If worktree doesn't exist, nothing to do
    if [[ ! -d "$wt_path" ]]; then
        git worktree prune 2>/dev/null || true
        return 0
    fi

    # Force remove the worktree (even if it has uncommitted changes)
    if ! git worktree remove --force "$wt_path" 2>/dev/null; then
        # Fallback: manually remove directory and prune
        rm -rf "$wt_path" 2>/dev/null || true
    fi

    # Prune stale entries from git's internal worktree list
    git worktree prune 2>/dev/null || true

    return 0
}
