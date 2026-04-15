#!/bin/bash
###
# SubagentStart Hook - Creates an Agent task span as child of current Turn
# Subsequent PostToolUse events with matching agent_id will attach to this span
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SubagentStart hook triggered"
tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
debug "SubagentStart input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "Agent"' 2>/dev/null)
AGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0
[ -z "$AGENT_ID" ] && { debug "SubagentStart missing agent_id"; exit 0; }

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

[ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "No active turn for SubagentStart"; exit 0; }

AGENT_SPAN_ID=$(generate_uuid)
START_TIME=$(get_epoch)
TIMESTAMP=$(get_timestamp)

EVENT=$(jq -n \
    --arg id "$AGENT_SPAN_ID" \
    --arg span_id "$AGENT_SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg parent "$TURN_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg agent_id "$AGENT_ID" \
    --arg agent_type "$AGENT_TYPE" \
    --arg transcript "$AGENT_TRANSCRIPT" \
    --arg name "$AGENT_TYPE" \
    --argjson start_time "$START_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$parent],
        created: $created,
        metrics: { start: $start_time },
        metadata: {
            agent_id: $agent_id,
            agent_type: $agent_type,
            agent_transcript_path: $transcript
        },
        span_attributes: {
            name: $name,
            type: "task"
        }
    }')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null || { log "ERROR" "SubagentStart insert failed"; exit 0; }

set_session_state "$SESSION_ID" "agent_span_${AGENT_ID}" "$AGENT_SPAN_ID"
set_session_state "$SESSION_ID" "agent_start_${AGENT_ID}" "$START_TIME"

log "INFO" "SubagentStart: $AGENT_TYPE (agent_id=$AGENT_ID, span=$AGENT_SPAN_ID)"

exit 0
