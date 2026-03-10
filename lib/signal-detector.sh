#!/usr/bin/env bash
# signal-detector.sh - Detects phase completion signals from accumulated text output

# Valid signals
readonly SIGNAL_PHASE_COMPLETE="PHASE_COMPLETE"
readonly SIGNAL_PHASE_IN_PROGRESS="PHASE_IN_PROGRESS"
readonly SIGNAL_ALL_PHASES_COMPLETE="ALL_PHASES_COMPLETE"
readonly SIGNAL_NONE=""

# Detect a signal from accumulated text
# Scans for trigger phrases. Returns the most specific / last signal found.
# ALL_PHASES_COMPLETE takes priority over PHASE_COMPLETE which takes priority over PHASE_IN_PROGRESS.
# Args: $1 = text to scan (or reads from stdin if no argument)
# Outputs the detected signal to stdout (empty string if none found)
detect_signal() {
    local text=""
    if [[ $# -gt 0 ]]; then
        text="$1"
    else
        text=$(cat)
    fi

    # Check for signals - most specific first
    # Use word-boundary matching to avoid false positives
    if echo "$text" | grep -qE '(^|[[:space:]])ALL_PHASES_COMPLETE($|[[:space:]])'; then
        echo "$SIGNAL_ALL_PHASES_COMPLETE"
        return 0
    fi

    if echo "$text" | grep -qE '(^|[[:space:]])PHASE_COMPLETE($|[[:space:]])'; then
        echo "$SIGNAL_PHASE_COMPLETE"
        return 0
    fi

    if echo "$text" | grep -qE '(^|[[:space:]])PHASE_IN_PROGRESS($|[[:space:]])'; then
        echo "$SIGNAL_PHASE_IN_PROGRESS"
        return 0
    fi

    echo "$SIGNAL_NONE"
    return 1
}

# Check if a detected signal is valid (non-empty)
# Args: $1 = signal string
# Returns 0 if valid, 1 if not
is_valid_signal() {
    local signal="$1"
    case "$signal" in
        "$SIGNAL_PHASE_COMPLETE"|"$SIGNAL_PHASE_IN_PROGRESS"|"$SIGNAL_ALL_PHASES_COMPLETE")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
