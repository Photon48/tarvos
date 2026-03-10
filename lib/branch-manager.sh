#!/usr/bin/env bash
# branch-manager.sh - Git branch operations for Tarvos async ecosystem

# ──────────────────────────────────────────────────────────────
# branch_ensure_clean
# Fail if the working directory has uncommitted changes.
# Returns 0 if clean, exits with error message if dirty.
# ──────────────────────────────────────────────────────────────
branch_ensure_clean() {
    # Must be inside a git repo
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "tarvos: not a git repository. Branch isolation requires git." >&2
        return 1
    fi

    # Detached HEAD check
    local head_ref
    head_ref=$(git symbolic-ref HEAD 2>/dev/null || true)
    if [[ -z "$head_ref" ]]; then
        echo "tarvos: git is in detached HEAD state. Please checkout a branch first." >&2
        return 1
    fi

    # Check for uncommitted changes (staged or unstaged)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo "tarvos: working directory has uncommitted changes." >&2
        echo "  Please commit or stash your changes before starting a session." >&2
        echo "  Run: git stash  (to stash changes)" >&2
        echo "       git commit -am 'wip'  (to commit them)" >&2
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────
# branch_get_current
# Return the current branch name.
# Returns 0 on success, 1 if in detached HEAD or not a git repo.
# ──────────────────────────────────────────────────────────────
branch_get_current() {
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "tarvos: not a git repository." >&2
        return 1
    fi

    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    if [[ -z "$branch" ]]; then
        echo "tarvos: git is in detached HEAD state." >&2
        return 1
    fi

    echo "$branch"
    return 0
}

# ──────────────────────────────────────────────────────────────
# branch_exists
# Check if a branch exists locally.
# Args: $1 = branch name
# Returns 0 if exists, 1 if not.
# ──────────────────────────────────────────────────────────────
branch_exists() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────
# branch_create
# Create a new tarvos/<session_name>-<timestamp> branch from the
# current branch, then checkout into it.
# Args: $1 = session_name
# Outputs: the new branch name
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────
branch_create() {
    local session_name="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local new_branch="tarvos/${session_name}-${timestamp}"

    if ! git checkout -b "$new_branch" 2>/dev/null; then
        echo "tarvos: failed to create branch '${new_branch}'." >&2
        return 1
    fi

    echo "$new_branch"
    return 0
}

# ──────────────────────────────────────────────────────────────
# branch_checkout
# Checkout an existing branch.
# Args: $1 = branch name
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────
branch_checkout() {
    local branch="$1"

    if ! branch_exists "$branch"; then
        echo "tarvos: branch '${branch}' does not exist." >&2
        return 1
    fi

    if ! git checkout "$branch" 2>/dev/null; then
        echo "tarvos: failed to checkout branch '${branch}'." >&2
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────
# branch_merge
# Merge source branch into target branch (no fast-forward).
# On conflict: aborts the merge and returns 1.
# Args: $1 = source_branch, $2 = target_branch
# Returns 0 on success, 1 on conflict or failure.
# ──────────────────────────────────────────────────────────────
branch_merge() {
    local source="$1"
    local target="$2"

    # Checkout the target first
    if ! git checkout "$target" 2>/dev/null; then
        echo "tarvos: failed to checkout target branch '${target}'." >&2
        return 1
    fi

    # Attempt merge
    if git merge --no-ff "$source" -m "tarvos: merge session branch ${source}" 2>/dev/null; then
        return 0
    fi

    # Merge failed — abort and report
    git merge --abort 2>/dev/null || true
    echo "tarvos: merge conflict detected when merging '${source}' into '${target}'." >&2
    echo "  Merge aborted. To resolve manually:" >&2
    echo "    git checkout ${target}" >&2
    echo "    git merge ${source}" >&2
    echo "  Resolve conflicts, then: git commit" >&2
    return 1
}

# ──────────────────────────────────────────────────────────────
# branch_delete
# Delete a local branch (force delete).
# Args: $1 = branch name
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────
branch_delete() {
    local branch="$1"

    if ! branch_exists "$branch"; then
        # Already gone — treat as success
        return 0
    fi

    if ! git branch -D "$branch" 2>/dev/null; then
        echo "tarvos: failed to delete branch '${branch}'." >&2
        return 1
    fi

    return 0
}
