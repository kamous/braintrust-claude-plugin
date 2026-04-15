#!/bin/bash
###
# SubagentStop Hook - Closes Agent task span; sets output and end time.
# Rich token / duration / toolStats metrics are merged separately by post_tool_use.sh
# when the parent Agent tool result arrives.
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SubagentStop hook triggered"
tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
debug "SubagentStop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
AGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0
[ -z "$AGENT_ID" ] && { debug "SubagentStop missing agent_id"; exit 0; }

PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
AGENT_SPAN_ID=$(get_session_state "$SESSION_ID" "agent_span_${AGENT_ID}")

if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

[ -z "$AGENT_SPAN_ID" ] && { debug "No agent span for $AGENT_ID, SubagentStart may have been missed"; exit 0; }
[ -z "$PROJECT_ID" ] && exit 0

END_TIME=$(get_epoch)

UPDATE=$(jq -n \
    --arg id "$AGENT_SPAN_ID" \
    --arg output "$LAST_MSG" \
    --arg transcript "$AGENT_TRANSCRIPT" \
    --arg agent_type "$AGENT_TYPE" \
    --argjson end_time "$END_TIME" \
    '{
        id: $id,
        _is_merge: true,
        output: $output,
        metrics: { end: $end_time },
        metadata: {
            agent_transcript_path: $transcript,
            agent_type: $agent_type
        }
    }')

insert_span "$PROJECT_ID" "$UPDATE" >/dev/null || log "WARN" "SubagentStop merge failed"

log "INFO" "SubagentStop: $AGENT_TYPE (agent_id=$AGENT_ID)"

# Parse the sub-agent's own transcript and emit its LLM spans as children of the Agent span.
# Fallback: Claude Code stores these at <session_dir>/subagents/agent-<agent_id>.jsonl.
if [ -z "$AGENT_TRANSCRIPT" ] || [ ! -f "$AGENT_TRANSCRIPT" ]; then
    SESSION_DIR=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
    [ -n "$SESSION_DIR" ] && AGENT_TRANSCRIPT="${SESSION_DIR%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
fi

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
if [ -f "$AGENT_TRANSCRIPT" ]; then
    debug "Processing sub-agent transcript: $AGENT_TRANSCRIPT"
    emit_llm_spans_for_transcript "$AGENT_TRANSCRIPT" "$AGENT_SPAN_ID" "agent_last_line_${AGENT_ID}" "$SESSION_ID" "$PROJECT_ID" "$ROOT_SPAN_ID"
else
    debug "Sub-agent transcript not found: $AGENT_TRANSCRIPT"
fi

exit 0
