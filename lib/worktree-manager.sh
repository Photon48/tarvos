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
# _worktree_base
# Return the absolute project root directory for worktree operations.
# Uses TARVOS_PROJECT_ROOT when set (so background workers that have
# cd'd into a worktree still resolve paths relative to the main repo).
# ──────────────────────────────────────────────────────────────
_worktree_base() {
    if [[ -n "${TARVOS_PROJECT_ROOT:-}" ]]; then
        echo "$TARVOS_PROJECT_ROOT"
    else
        pwd
    fi
}

# ──────────────────────────────────────────────────────────────
# worktree_exists
# Check if a worktree directory exists and is a valid git worktree.
# Args: $1 = session_name
# Returns 0 if exists, 1 if not.
# ──────────────────────────────────────────────────────────────
worktree_exists() {
    local session_name="$1"
    local base
    base=$(_worktree_base)
    local wt_path="${base}/.tarvos/worktrees/${session_name}"
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

    local base
    base=$(_worktree_base)
    local wt_path="${base}/.tarvos/worktrees/${session_name}"

    # Ensure parent directory exists
    mkdir -p "${base}/.tarvos/worktrees"

    # If worktree already exists, just return the path
    if worktree_exists "$session_name"; then
        echo "$wt_path"
        return 0
    fi

    # Create the worktree (suppress all output — both stdout and stderr — to avoid
    # "HEAD is now at ..." messages leaking into the captured return value).
    # Run git from the project root so it can find the repo correctly.
    if ! git -C "$base" worktree add "$wt_path" "$branch_name" &>/dev/null; then
        echo "tarvos: failed to create worktree at '${wt_path}' on branch '${branch_name}'." >&2
        return 1
    fi

    echo "$wt_path"
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
    local base
    base=$(_worktree_base)
    local wt_path="${base}/.tarvos/worktrees/${session_name}"

    # If worktree doesn't exist, nothing to do
    if [[ ! -d "$wt_path" ]]; then
        git -C "$base" worktree prune 2>/dev/null || true
        return 0
    fi

    # Force remove the worktree (even if it has uncommitted changes)
    if ! git -C "$base" worktree remove --force "$wt_path" 2>/dev/null; then
        # Fallback: manually remove directory and prune
        rm -rf "$wt_path" 2>/dev/null || true
    fi

    # Prune stale entries from git's internal worktree list
    git -C "$base" worktree prune 2>/dev/null || true

    return 0
}
