#!/usr/bin/env bash
# context-monitor.sh - Stream-json parser, token tracking, and process management

# Token tracking state
CURRENT_INPUT_TOKENS=0
CURRENT_OUTPUT_TOKENS=0
CONTEXT_LIMIT_HIT=0

# Events log path (set by caller via set_events_log or defaults to "")
_CM_EVENTS_LOG=""

# Set the events log file path for the current loop
set_events_log() {
    _CM_EVENTS_LOG="$1"
    [[ -n "$_CM_EVENTS_LOG" ]] && > "$_CM_EVENTS_LOG"
}

# Emit a structured TUI event to the events jsonl file
# Args: $1 = JSON object string (pre-built)
emit_tui_event() {
    local json="$1"
    if [[ -n "$_CM_EVENTS_LOG" ]]; then
        printf '%s\n' "$json" >> "$_CM_EVENTS_LOG"
    fi
}

# Reset token counters for a new iteration
reset_token_counters() {
    CURRENT_INPUT_TOKENS=0
    CURRENT_OUTPUT_TOKENS=0
    CONTEXT_LIMIT_HIT=0
}

# Get total tokens (input + output)
get_total_tokens() {
    echo $(( CURRENT_INPUT_TOKENS + CURRENT_OUTPUT_TOKENS ))
}

# Process the stream-json output from Claude CLI
# Reads NDJSON from stdin, extracts text and token usage
# Writes accumulated text to the text output file
# Writes raw JSONL to the raw log file
# Updates token counters and calls log functions
#
# Args: $1 = token limit, $2 = loop number, $3 = raw log file, $4 = text output file
# Returns: 0 on normal completion, 1 on context limit hit
process_stream() {
    local token_limit="$1"
    local loop_num="$2"
    local raw_log="$3"
    local text_output="$4"

    # Ensure output files exist
    > "$text_output"
    > "$raw_log"

    local line
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Write raw line to log
        echo "$line" >> "$raw_log"

        # Try to parse as JSON and extract relevant data
        local event_type
        event_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        # Check if this event is from a subagent (has parent_tool_use_id).
        # Subagents have their own separate context window — their usage must
        # NOT be mixed with the main agent's context tracking.
        local is_subagent
        is_subagent=$(echo "$line" | jq -r '.parent_tool_use_id // empty' 2>/dev/null)

        case "$event_type" in
            # Claude Code stream-json emits "assistant" type messages with content
            assistant)
                # Extract text content from the message (include subagent text for signal detection)
                local text
                text=$(echo "$line" | jq -r '
                    if .message.content then
                        [.message.content[] | select(.type == "text") | .text] | join("")
                    else
                        empty
                    end
                ' 2>/dev/null)
                if [[ -n "$text" ]]; then
                    echo "$text" >> "$text_output"
                    # Emit text event (truncated to 80 chars for events log)
                    if [[ -n "$_CM_EVENTS_LOG" ]] && [[ -z "$is_subagent" ]]; then
                        local brief_text="${text:0:80}"
                        brief_text="${brief_text//$'\n'/ }"
                        local ts
                        ts=$(date +%s)
                        emit_tui_event "{\"type\":\"text\",\"content\":$(printf '%s' "$brief_text" | jq -Rs '.'),\"ts\":${ts}}"
                    fi
                fi

                # Emit tool_use events from assistant message content
                if [[ -n "$_CM_EVENTS_LOG" ]] && [[ -z "$is_subagent" ]]; then
                    local tool_events
                    tool_events=$(echo "$line" | jq -c '
                        if .message.content then
                            .message.content[] | select(.type == "tool_use") | {type:"tool_use", tool:.name, input:((.input | tostring)[0:80]), id:.id}
                        else
                            empty
                        end
                    ' 2>/dev/null)
                    if [[ -n "$tool_events" ]]; then
                        local ts
                        ts=$(date +%s)
                        while IFS= read -r ev; do
                            [[ -z "$ev" ]] && continue
                            emit_tui_event "$(echo "$ev" | jq -c --argjson ts "$ts" '. + {ts:$ts}')"
                        done <<< "$tool_events"
                    fi
                fi

                # Only track usage from the main agent, not subagents
                if [[ -z "$is_subagent" ]]; then
                    extract_usage_from_line "$line" "$loop_num" "$token_limit"
                fi
                ;;

            # Emit tool_result events
            tool_result)
                if [[ -n "$_CM_EVENTS_LOG" ]] && [[ -z "$is_subagent" ]]; then
                    local ts
                    ts=$(date +%s)
                    local tool_id output success
                    tool_id=$(echo "$line" | jq -r '.tool_use_id // ""' 2>/dev/null)
                    output=$(echo "$line" | jq -r '(.content // "") | if type == "array" then .[0].text // "" else . end' 2>/dev/null)
                    output="${output:0:80}"
                    output="${output//$'\n'/ }"
                    success=$(echo "$line" | jq -r 'if .is_error then "false" else "true" end' 2>/dev/null)
                    emit_tui_event "{\"type\":\"tool_result\",\"tool_use_id\":$(printf '%s' "$tool_id" | jq -Rs '.'),\"output\":$(printf '%s' "$output" | jq -Rs '.'),\"success\":${success:-true},\"ts\":${ts}}"
                fi
                if [[ -z "$is_subagent" ]]; then
                    extract_usage_from_line "$line" "$loop_num" "$token_limit"
                fi
                ;;

            # Handle result type (final message)
            result)
                local text
                text=$(echo "$line" | jq -r '
                    if .result then .result
                    elif .subtype == "success" then ""
                    else empty
                    end
                ' 2>/dev/null)
                if [[ -n "$text" ]]; then
                    echo "$text" >> "$text_output"
                    # Check for signal in result text and emit signal event
                    if [[ -n "$_CM_EVENTS_LOG" ]]; then
                        local sig_found=""
                        for sig in PHASE_COMPLETE PHASE_IN_PROGRESS ALL_PHASES_COMPLETE; do
                            if [[ "$text" == *"$sig"* ]]; then
                                sig_found="$sig"
                                break
                            fi
                        done
                        if [[ -n "$sig_found" ]]; then
                            local ts
                            ts=$(date +%s)
                            emit_tui_event "{\"type\":\"signal\",\"signal\":\"${sig_found}\",\"ts\":${ts}}"
                        fi
                    fi
                fi

                if [[ -z "$is_subagent" ]]; then
                    extract_usage_from_line "$line" "$loop_num" "$token_limit"
                fi
                ;;

            # Handle system messages
            system)
                if [[ -z "$is_subagent" ]]; then
                    extract_usage_from_line "$line" "$loop_num" "$token_limit"
                fi
                ;;

            *)
                if [[ -z "$is_subagent" ]]; then
                    extract_usage_from_line "$line" "$loop_num" "$token_limit"
                fi
                ;;
        esac

        # Check if context limit was hit
        if (( CONTEXT_LIMIT_HIT )); then
            return 1
        fi
    done

    return 0
}

# Extract usage data from a JSON line and update counters
# The stream-json format includes cache token fields that represent the bulk of context usage:
#   input_tokens              - uncached input tokens
#   cache_creation_input_tokens - tokens written to cache this turn
#   cache_read_input_tokens   - tokens read from cache
#   output_tokens             - tokens generated in response
# Total context = all input fields summed (represents actual context window usage)
# Args: $1 = JSON line, $2 = loop number, $3 = token limit
extract_usage_from_line() {
    local line="$1"
    local loop_num="$2"
    local token_limit="$3"

    # Extract all token fields from the usage object
    # Try .message.usage first (assistant events), then top-level .usage
    local usage_json
    usage_json=$(echo "$line" | jq -r '
        (.message.usage // .usage // .result_usage // null)
    ' 2>/dev/null)

    [[ -z "$usage_json" || "$usage_json" == "null" ]] && return 0

    local input_tokens cache_creation cache_read output_tokens
    input_tokens=$(echo "$usage_json" | jq -r '.input_tokens // 0' 2>/dev/null)
    cache_creation=$(echo "$usage_json" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
    cache_read=$(echo "$usage_json" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$usage_json" | jq -r '.output_tokens // 0' 2>/dev/null)

    # Compute total input (context window size) = uncached + cache_creation + cache_read
    local total_input=0
    [[ "$input_tokens" =~ ^[0-9]+$ ]] && total_input=$((total_input + input_tokens))
    [[ "$cache_creation" =~ ^[0-9]+$ ]] && total_input=$((total_input + cache_creation))
    [[ "$cache_read" =~ ^[0-9]+$ ]] && total_input=$((total_input + cache_read))

    local out=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] && out=$output_tokens

    # Only update if we got meaningful data
    if (( total_input > 0 || out > 0 )); then
        # Take the latest values (each API call reports full context size)
        CURRENT_INPUT_TOKENS=$total_input
        CURRENT_OUTPUT_TOKENS=$out

        log_usage_snapshot "$loop_num" "$CURRENT_INPUT_TOKENS" "$CURRENT_OUTPUT_TOKENS"

        local total
        total=$(get_total_tokens)

        # Update progress bar
        log_token_progress "$total" "$token_limit"

        # Emit token event to TUI
        if (( total > 0 )); then
            local ts
            ts=$(date +%s)
            emit_tui_event "{\"type\":\"tokens\",\"tokens\":${total},\"ts\":${ts}}"
        fi

        # Check context limit
        if (( total >= token_limit )); then
            CONTEXT_LIMIT_HIT=1
        fi
    fi
}

# Kill a Claude process gracefully, then forcefully if needed
# Args: $1 = PID
kill_claude_process() {
    local pid="$1"

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0  # Already dead
    fi

    # Graceful SIGTERM
    kill -TERM "$pid" 2>/dev/null

    # Wait up to 2 seconds for graceful shutdown
    local waited=0
    while (( waited < 20 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        (( waited++ ))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi

    return 0
}

# Run the context-limit continuation session
# Uses `claude -c` to continue the existing session and ask the agent to write progress.md
# Args: $1 = continuation prompt, $2 = raw log file (for continuation), $3 = text output file (appended)
# Returns: 0 on success, 1 on failure
run_continuation_session() {
    local prompt="$1"
    local raw_log="$2"
    local text_output="$3"

    log_info "Running continuation session (claude -c) to write progress.md..."

    local tmp_output
    tmp_output=$(mktemp)

    # Run in background so CLAUDE_PID is set and Ctrl+C trap can kill it
    claude -c -p "$prompt" --dangerously-skip-permissions --verbose --output-format stream-json > "$tmp_output" 2>/dev/null &
    CLAUDE_PID=$!

    # wait is interruptible by signals (unlike foreground commands)
    wait "$CLAUDE_PID" 2>/dev/null
    local exit_code=$?
    CLAUDE_PID=""

    local continuation_output
    continuation_output=$(cat "$tmp_output" 2>/dev/null)
    rm -f "$tmp_output"

    # Append raw output to log
    echo "$continuation_output" >> "$raw_log"

    # Extract text from the continuation output
    local text
    text=$(echo "$continuation_output" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$line" | jq -r '
            if .type == "assistant" then
                [.message.content[]? | select(.type == "text") | .text] | join("")
            elif .type == "result" then
                .result // empty
            else
                empty
            end
        ' 2>/dev/null
    done)

    if [[ -n "$text" ]]; then
        echo "$text" >> "$text_output"
    fi

    return $exit_code
}

# Run a standalone recovery session when progress.md is missing
# Args: $1 = prompt, $2 = project directory, $3 = expected progress file path (optional)
# Returns: 0 on success, 1 on failure
run_recovery_session() {
    local prompt="$1"
    local project_dir="$2"
    local expected_progress_file="${3:-${project_dir}/progress.md}"

    log_warning "Running standalone recovery session to generate progress.md..."

    local stderr_log
    stderr_log=$(mktemp)

    # Run in background so CLAUDE_PID is set and Ctrl+C trap can kill it
    claude -p "$prompt" --dangerously-skip-permissions > /dev/null 2>"$stderr_log" &
    CLAUDE_PID=$!

    # wait is interruptible by signals (unlike foreground commands)
    wait "$CLAUDE_PID" 2>/dev/null
    local exit_code=$?
    CLAUDE_PID=""

    # Report errors
    if [[ $exit_code -ne 0 ]]; then
        if [[ -s "$stderr_log" ]]; then
            log_error "Recovery claude exit code ${exit_code}: $(head -c 300 "$stderr_log" | tr '\n' ' ')"
        else
            log_error "Recovery claude exited with code ${exit_code}"
        fi
    fi
    rm -f "$stderr_log"

    if [[ -f "$expected_progress_file" ]]; then
        log_success "Recovery session created progress.md"
        return 0
    else
        log_error "Recovery session failed to create progress.md"
        return 1
    fi
}
