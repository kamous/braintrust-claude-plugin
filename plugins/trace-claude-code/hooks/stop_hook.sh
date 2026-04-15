#!/bin/bash
###
# Stop Hook - Emits LLM spans for the main transcript under the current Turn span,
# then closes the Turn span.
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "Stop hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(read_canonical_event "agent_stop")
debug "Stop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    [ -n "$TRANSCRIPT_PATH" ] && SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

[ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "No current turn to finalize"; exit 0; }

CONV_FILE=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ]; then
    CONV_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
fi

if [ -n "$CONV_FILE" ] && [ -f "$CONV_FILE" ]; then
    debug "Processing main transcript: $CONV_FILE"
    emit_llm_spans_for_transcript "$CONV_FILE" "$TURN_SPAN_ID" "turn_last_line" "$SESSION_ID" "$PROJECT_ID" "$ROOT_SPAN_ID"
fi

# Close the Turn span
END_TIME=$(get_epoch)
TURN_UPDATE=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --argjson end_time "$END_TIME" \
    '{id:$id, _is_merge:true, metrics:{end:$end_time}}')
insert_span "$PROJECT_ID" "$TURN_UPDATE" >/dev/null || true

set_session_state "$SESSION_ID" "current_turn_span_id" ""
log "INFO" "Turn finalized"

exit 0
