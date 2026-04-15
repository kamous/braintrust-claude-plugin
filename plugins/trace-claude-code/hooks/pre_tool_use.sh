#!/bin/bash
###
# PreToolUse Hook - Records tool start time for accurate duration in PostToolUse
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PreToolUse hook triggered"
tracing_enabled || exit 0

INPUT=$(read_canonical_event "pre_tool")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0

# Copilot CLI doesn't provide tool_use_id; synthesize one and store it so
# post_tool_use.sh can reconstruct the pair via copilot_pending_tool_id.
if [ -z "$TOOL_USE_ID" ]; then
    TOOL_USE_ID=$(generate_uuid)
    set_session_state "$SESSION_ID" "copilot_pending_tool_id" "$TOOL_USE_ID"
fi

START=$(get_epoch)
set_session_state "$SESSION_ID" "tool_start_${TOOL_USE_ID}" "$START"

exit 0
