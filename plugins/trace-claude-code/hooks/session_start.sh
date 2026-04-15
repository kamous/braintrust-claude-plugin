#!/bin/bash
###
# SessionStart Hook - Creates the root trace span when a Claude Code session begins
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SessionStart hook triggered"
debug "TRACE_TO_BRAINTRUST=$TRACE_TO_BRAINTRUST"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(read_canonical_event "session_start")
debug "SessionStart input: $INPUT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    # Generate a session ID if not provided
    SESSION_ID=$(generate_uuid)
    debug "Generated session ID: $SESSION_ID"
fi

# Determine mode and get appropriate IDs
if is_experiment_mode; then
    debug "Experiment mode: CC_EXPERIMENT_ID=$CC_EXPERIMENT_ID"
    # In experiment mode, we still get project_id for state management
    # but spans are inserted to the experiment endpoint
    PROJECT_ID=$(get_project_id "$PROJECT") || PROJECT_ID="experiment-mode"
    log "INFO" "Tracing to experiment: $CC_EXPERIMENT_ID"
else
    # Get project ID for project_logs mode
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; exit 0; }
    debug "Using project: $PROJECT (id: $PROJECT_ID)"
fi

# Create the session span
# If CC_PARENT_SPAN_ID is set, this session becomes a child of an existing trace
if [ -n "$CC_PARENT_SPAN_ID" ]; then
    ROOT_SPAN_ID="$CC_ROOT_SPAN_ID"
    debug "Attaching to parent span: $CC_PARENT_SPAN_ID (root: $ROOT_SPAN_ID)"
else
    ROOT_SPAN_ID="$SESSION_ID"
fi
SPAN_ID="$SESSION_ID"
TIMESTAMP=$(get_timestamp)

# Atomically check if we already have a root span for this session and set it if not
# This prevents race conditions when session_start is called multiple times
if ! check_and_set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"; then
    EXISTING_ROOT=$(get_session_state "$SESSION_ID" "root_span_id")
    debug "Session already has root span (race avoided): $EXISTING_ROOT"
    exit 0
fi
debug "Claimed session root span: $ROOT_SPAN_ID"

# Extract workspace info if available
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
RUNTIME=$(echo "$INPUT" | jq -r '.runtime // "claude"' 2>/dev/null)
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

# Get system info
HOSTNAME=$(get_hostname)
USERNAME=$(get_username)
OS=$(get_os)

case "$RUNTIME" in
    copilot) RUNTIME_LABEL="Copilot CLI" ;;
    codex)   RUNTIME_LABEL="Codex CLI" ;;
    *)       RUNTIME_LABEL="Claude Code" ;;
esac

EVENT=$(jq -n \
    --arg id "$SPAN_ID" \
    --arg span_id "$SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg session "$SESSION_ID" \
    --arg workspace "$WORKSPACE_NAME" \
    --arg cwd "$WORKSPACE" \
    --arg hostname "$HOSTNAME" \
    --arg username "$USERNAME" \
    --arg os "$OS" \
    --arg runtime "$RUNTIME" \
    --arg label "$RUNTIME_LABEL" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        created: $created,
        input: ("Session: " + $workspace),
        metadata: {
            session_id: $session,
            workspace: $cwd,
            hostname: $hostname,
            username: $username,
            os: $os,
            runtime: $runtime
        },
        span_attributes: {
            name: ($label + ": " + $workspace),
            type: "task"
        }
    }')

# Add span_parents if attaching to an existing trace
if [ -n "$CC_PARENT_SPAN_ID" ]; then
    debug "Setting span_parents to: $CC_PARENT_SPAN_ID"
    EVENT=$(echo "$EVENT" | jq --arg parent "$CC_PARENT_SPAN_ID" '. + {span_parents: [$parent]}')
fi

ROW_ID=$(insert_span "$PROJECT_ID" "$EVENT") || { log "ERROR" "Failed to create session root"; exit 0; }

# Save remaining session state (root_span_id was already set atomically above)
set_session_state "$SESSION_ID" "session_span_id" "$SPAN_ID"
set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
set_session_state "$SESSION_ID" "turn_count" "0"
set_session_state "$SESSION_ID" "tool_count" "0"
set_session_state "$SESSION_ID" "started" "$TIMESTAMP"

# Store experiment_id if in experiment mode
if is_experiment_mode; then
    set_session_state "$SESSION_ID" "experiment_id" "$CC_EXPERIMENT_ID"
    log "INFO" "Created session root: $SESSION_ID workspace=$WORKSPACE_NAME (experiment=$CC_EXPERIMENT_ID)"
else
    log "INFO" "Created session root: $SESSION_ID workspace=$WORKSPACE_NAME (project=$PROJECT)"
fi

# Copilot CLI: task sessions never receive userPromptSubmitted, so pre-create
# Turn 1 here.  UserPromptSubmit will overwrite current_turn_span_id when it
# does fire (main session), making this a no-op for that case.
if [ "${CC_RUNTIME:-claude}" = "copilot" ]; then
    TURN_SPAN_ID=$(generate_uuid)
    TURN_START=$(get_epoch)
    TURN_EVENT=$(jq -n \
        --arg id "$TURN_SPAN_ID" \
        --arg root "$ROOT_SPAN_ID" \
        --arg parent "$SPAN_ID" \
        --arg created "$TIMESTAMP" \
        --argjson start "$TURN_START" \
        '{
            id: $id, span_id: $id,
            root_span_id: $root,
            span_parents: [$parent],
            created: $created,
            metrics: { start: $start },
            span_attributes: { name: "Turn 1", type: "task" }
        }')
    insert_span "$PROJECT_ID" "$TURN_EVENT" >/dev/null \
        && set_session_state "$SESSION_ID" "current_turn_span_id" "$TURN_SPAN_ID" \
        && set_session_state "$SESSION_ID" "turn_count" "1" \
        && set_session_state "$SESSION_ID" "turn_span_1" "$TURN_SPAN_ID" \
        && set_session_state "$SESSION_ID" "turn_start_1" "$TURN_START" \
        && log "INFO" "Pre-created Turn 1 for Copilot task session ($TURN_SPAN_ID)" \
        || true
fi

# Stash cwd so session_end.sh / copilot_events.sh can locate the native
# Copilot session-state directory and backfill LLM/sub-agent spans.
[ -n "$WORKSPACE" ] && set_session_state "$SESSION_ID" "cwd" "$WORKSPACE"

exit 0
