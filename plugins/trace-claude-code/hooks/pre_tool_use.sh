#!/bin/bash
###
# PreToolUse Hook - Records tool start time for accurate duration in PostToolUse
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PreToolUse hook triggered"
tracing_enabled || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0
[ -z "$TOOL_USE_ID" ] && exit 0

START=$(get_epoch)
set_session_state "$SESSION_ID" "tool_start_${TOOL_USE_ID}" "$START"

exit 0
