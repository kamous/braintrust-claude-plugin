#!/bin/bash
###
# PostToolUse Hook
#
# - Normal tools: create a tool span, parent = Agent span (if agent_id) or Turn span.
#   Real duration via PreToolUse-recorded start time.
# - Tool "Agent": don't create a new span; merge rich metrics (tokens incl. cache,
#   totalDurationMs, toolStats, last_assistant_message) into the Agent task span
#   created by SubagentStart.
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PostToolUse hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "PostToolUse input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
TOOL_OUTPUT_RAW=$(echo "$INPUT" | jq -c '.tool_response // .output // {}' 2>/dev/null)

# Detect tool failure for span `error` field.
# Anthropic tool_response convention: is_error:true; also treat Bash non-zero exit codes as failure.
TOOL_ERROR=""
if [ -n "$TOOL_OUTPUT_RAW" ] && [ "$TOOL_OUTPUT_RAW" != "{}" ]; then
    IS_ERR=$(echo "$TOOL_OUTPUT_RAW" | jq -r '(.is_error // false) | tostring' 2>/dev/null)
    ERR_MSG=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.error // .error_message // empty' 2>/dev/null)
    EXIT_CODE=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.exit_code // empty' 2>/dev/null)
    if [ "$IS_ERR" = "true" ] || [ -n "$ERR_MSG" ] || { [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "null" ]; }; then
        TOOL_ERROR="${ERR_MSG:-tool returned error}${EXIT_CODE:+ (exit=$EXIT_CODE)}"
    fi
fi

# Truncate potentially-huge payloads (e.g. Read of a 500KB file).
TOOL_INPUT=$(truncate_json_payload "$TOOL_INPUT")
TOOL_OUTPUT=$(truncate_json_payload "$TOOL_OUTPUT_RAW")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)

[ -z "$TOOL_NAME" ] && exit 0
[ -z "$SESSION_ID" ] && exit 0

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

[ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "No current turn"; exit 0; }

END_TIME=$(get_epoch)

# Determine accurate start/end from the transcript by tool_use_id.
# Hook dispatch is async and can lag several hundred ms; transcript message
# timestamps reflect the actual tool_use / tool_result moments.
START_TIME=""
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$AGENT_ID" ] && [ -n "$TRANSCRIPT_PATH" ]; then
    SUB_TRANS="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
    [ -f "$SUB_TRANS" ] && TRANSCRIPT_PATH="$SUB_TRANS"
fi
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -n "$TOOL_USE_ID" ]; then
    TOOL_USE_TS=$(jq -r --arg id "$TOOL_USE_ID" \
        'select(.type=="assistant" and ((.message.content // []) | any(.type=="tool_use" and .id==$id))) | .timestamp // empty' \
        "$TRANSCRIPT_PATH" 2>/dev/null | head -1)
    TOOL_RESULT_TS=$(jq -r --arg id "$TOOL_USE_ID" \
        'select(.type=="user" and ((.message.content // []) | any(.type=="tool_result" and .tool_use_id==$id))) | .timestamp // empty' \
        "$TRANSCRIPT_PATH" 2>/dev/null | head -1)
    [ -n "$TOOL_USE_TS" ] && START_TIME=$(iso_to_epoch "$TOOL_USE_TS")
    [ -n "$TOOL_RESULT_TS" ] && END_TIME=$(iso_to_epoch "$TOOL_RESULT_TS")
fi
# Fallback: use PreToolUse-recorded start if transcript lookup failed
if [ -z "$START_TIME" ] && [ -n "$TOOL_USE_ID" ]; then
    START_TIME=$(get_session_state "$SESSION_ID" "tool_start_${TOOL_USE_ID}")
fi
[ -z "$START_TIME" ] && START_TIME="$END_TIME"

###
# Special case: Agent tool. Merge rich metrics into the existing Agent task span.
###
if [ "$TOOL_NAME" = "Agent" ]; then
    SUB_AGENT_ID=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.agentId // empty' 2>/dev/null)
    AGENT_SPAN_ID=""
    [ -n "$SUB_AGENT_ID" ] && AGENT_SPAN_ID=$(get_session_state "$SESSION_ID" "agent_span_${SUB_AGENT_ID}")

    if [ -z "$AGENT_SPAN_ID" ]; then
        debug "Agent tool but no SubagentStart span found (agentId=$SUB_AGENT_ID); skipping"
        exit 0
    fi

    AGENT_TYPE=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.agentType // "Agent"' 2>/dev/null)
    DURATION_MS=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.totalDurationMs // 0' 2>/dev/null)
    TOTAL_TOKENS=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.totalTokens // 0' 2>/dev/null)
    TOTAL_TOOLS=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.totalToolUseCount // 0' 2>/dev/null)
    LAST_TEXT=$(echo "$TOOL_OUTPUT_RAW" | jq -r '[.content[]? | select(.type=="text") | .text] | join("\n") // ""' 2>/dev/null)
    INPUT_TOKENS=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    OUTPUT_TOKENS=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    CACHE_READ=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null)
    CACHE_CREATE=$(echo "$TOOL_OUTPUT_RAW" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null)
    # Braintrust expects prompt_tokens = total input tokens (denominator for cache_hit%).
    # Anthropic's .usage.input_tokens is only the non-cached portion, so sum all three.
    PROMPT_TOTAL=$((INPUT_TOKENS + CACHE_READ + CACHE_CREATE))
    TOOL_STATS=$(echo "$TOOL_OUTPUT_RAW" | jq -c '.toolStats // {}' 2>/dev/null)

    # Use totalDurationMs to refine start time (more accurate than SubagentStart hook timing)
    if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
        REFINED_START=$(python3 -c "print(f'{$END_TIME - $DURATION_MS/1000:.3f}')" 2>/dev/null) || REFINED_START="$START_TIME"
    else
        REFINED_START=$(get_session_state "$SESSION_ID" "agent_start_${SUB_AGENT_ID}")
        [ -z "$REFINED_START" ] && REFINED_START="$START_TIME"
    fi

    UPDATE=$(jq -n \
        --arg id "$AGENT_SPAN_ID" \
        --arg agent_type "$AGENT_TYPE" \
        --argjson tool_input "$TOOL_INPUT" \
        --arg output "$LAST_TEXT" \
        --argjson start "$REFINED_START" \
        --argjson end "$END_TIME" \
        --argjson prompt_tokens "$PROMPT_TOTAL" \
        --argjson completion_tokens "$OUTPUT_TOKENS" \
        --argjson cached_tokens "$CACHE_READ" \
        --argjson cache_creation_tokens "$CACHE_CREATE" \
        --argjson total_tool_uses "$TOOL_STATS" \
        --argjson total_tools "$TOTAL_TOOLS" \
        --argjson total_tokens "$TOTAL_TOKENS" \
        '{
            id: $id,
            _is_merge: true,
            input: $tool_input,
            output: $output,
            metrics: {
                start: $start,
                end: $end,
                prompt_tokens: $prompt_tokens,
                completion_tokens: $completion_tokens,
                prompt_cached_tokens: $cached_tokens,
                prompt_cache_creation_tokens: $cache_creation_tokens,
                tokens: $total_tokens,
                tool_use_count: $total_tools
            },
            metadata: {
                agent_type: $agent_type,
                tool_stats: $total_tool_uses
            }
        }')

    insert_span "$PROJECT_ID" "$UPDATE" >/dev/null || log "WARN" "Agent merge failed"
    log "INFO" "Agent merged: $AGENT_TYPE (agent_id=$SUB_AGENT_ID, dur=${DURATION_MS}ms, tokens=$TOTAL_TOKENS)"

    [ -n "$TOOL_USE_ID" ] && set_session_state "$SESSION_ID" "tool_start_${TOOL_USE_ID}" ""
    exit 0
fi

###
# Normal tool: decide parent (Agent span if agent_id, else Turn), create tool span.
###
PARENT_SPAN_ID="$TURN_SPAN_ID"
if [ -n "$AGENT_ID" ]; then
    AGENT_PARENT=$(get_session_state "$SESSION_ID" "agent_span_${AGENT_ID}")
    [ -n "$AGENT_PARENT" ] && PARENT_SPAN_ID="$AGENT_PARENT"
fi

# Increment tool count for this turn
TOOL_COUNT=$(get_session_state "$SESSION_ID" "current_turn_tool_count")
TOOL_COUNT=${TOOL_COUNT:-0}
TOOL_COUNT=$((TOOL_COUNT + 1))
set_session_state "$SESSION_ID" "current_turn_tool_count" "$TOOL_COUNT"

SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)

case "$TOOL_NAME" in
    Read|Write|Edit|MultiEdit)
        FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
        SPAN_NAME="$TOOL_NAME${FILE_PATH:+: $(basename "$FILE_PATH")}"
        ;;
    Bash|Terminal)
        CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null | head -c 50)
        SPAN_NAME="Terminal: ${CMD:-command}"
        ;;
    mcp__*)
        SPAN_NAME=$(echo "$TOOL_NAME" | sed 's/mcp__/MCP: /' | sed 's/__/ - /')
        ;;
    *)
        SPAN_NAME="$TOOL_NAME"
        ;;
esac

EVENT=$(jq -n \
    --arg id "$SPAN_ID" \
    --arg span_id "$SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg parent "$PARENT_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg tool "$TOOL_NAME" \
    --arg agent_id "$AGENT_ID" \
    --arg tool_use_id "$TOOL_USE_ID" \
    --arg error "$TOOL_ERROR" \
    --argjson input "$TOOL_INPUT" \
    --argjson output "$TOOL_OUTPUT" \
    --arg name "$SPAN_NAME" \
    --argjson start_time "$START_TIME" \
    --argjson end_time "$END_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$parent],
        created: $created,
        input: $input,
        output: $output,
        metrics: { start: $start_time, end: $end_time },
        metadata: {
            tool_name: $tool,
            agent_id: $agent_id,
            tool_use_id: $tool_use_id
        },
        span_attributes: { name: $name, type: "tool" }
    } + (if $error == "" then {} else {error:$error} end)')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null || { log "ERROR" "Failed to create tool span"; exit 0; }

[ -n "$TOOL_USE_ID" ] && set_session_state "$SESSION_ID" "tool_start_${TOOL_USE_ID}" ""

log "INFO" "Tool: $SPAN_NAME (parent=$PARENT_SPAN_ID, agent=${AGENT_ID:-main})"

exit 0
