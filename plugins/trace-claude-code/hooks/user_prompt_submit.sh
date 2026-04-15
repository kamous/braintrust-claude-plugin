#!/bin/bash
###
# UserPromptSubmit Hook - Creates a Turn container span when user submits a prompt
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(read_canonical_event "user_prompt")
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Copilot CLI: when a background sub-agent finishes, Copilot re-injects a
# "<system_notification>Agent X completed…</system_notification>" back into
# the main session as a userPromptSubmitted event. That is NOT a real user
# turn — it's the continuation of the prior turn. Skip Turn creation so the
# subsequent read_agent tool attaches to the existing Turn, and the trace
# matches the user's actual prompts.
case "$PROMPT" in
    "<system_notification>"*)
        # Re-open the last real Turn so the subsequent read_agent / summary
        # LLM calls attach there (stop_hook.sh cleared current_turn_span_id
        # when the prior Stop fired). Copilot's next real Stop will finalize
        # the extended Turn.
        _LAST_TURN=$(get_session_state "$SESSION_ID" "turn_count")
        _LAST_TURN=${_LAST_TURN:-1}
        _LAST_SPAN=$(get_session_state "$SESSION_ID" "turn_span_${_LAST_TURN}")
        [ -n "$_LAST_SPAN" ] && set_session_state "$SESSION_ID" "current_turn_span_id" "$_LAST_SPAN"
        debug "UserPromptSubmit: system_notification — reattached to Turn ${_LAST_TURN}"
        exit 0
        ;;
esac

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
SESSION_SPAN_ID=$(get_session_state "$SESSION_ID" "session_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")

# Load experiment_id from session state if not already set
if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

# If no session root exists yet, we'll create it
if [ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; exit 0; }
    ROOT_SPAN_ID="$SESSION_ID"

    # Get workspace name from cwd
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    WORKSPACE_NAME=$(basename "$CWD" 2>/dev/null || echo "workspace")

    TIMESTAMP=$(get_timestamp)
    HOSTNAME=$(get_hostname)
    USERNAME=$(get_username)
    OS=$(get_os)

    RUNTIME=$(echo "$INPUT" | jq -r '.runtime // "claude"' 2>/dev/null)
    case "$RUNTIME" in
        copilot) RUNTIME_LABEL="Copilot CLI" ;;
        codex)   RUNTIME_LABEL="Codex CLI" ;;
        *)       RUNTIME_LABEL="Claude Code" ;;
    esac

    EVENT=$(jq -n \
        --arg id "$ROOT_SPAN_ID" \
        --arg span_id "$ROOT_SPAN_ID" \
        --arg root_span_id "$ROOT_SPAN_ID" \
        --arg created "$TIMESTAMP" \
        --arg session "$SESSION_ID" \
        --arg workspace "$WORKSPACE_NAME" \
        --arg hostname "$HOSTNAME" \
        --arg username "$USERNAME" \
        --arg os "$OS" \
        --arg runtime "$RUNTIME" \
        --arg label "$RUNTIME_LABEL" \
        --arg prompt "$PROMPT" \
        '{
            id: $id,
            span_id: $span_id,
            root_span_id: $root_span_id,
            created: $created,
            input: $prompt,
            metadata: {
                session_id: $session,
                workspace: $workspace,
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

    insert_span "$PROJECT_ID" "$EVENT" >/dev/null || true
    set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "session_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
    [ -n "$CWD" ] && set_session_state "$SESSION_ID" "cwd" "$CWD"
    SESSION_SPAN_ID="$ROOT_SPAN_ID"
    log "INFO" "Created session root: $SESSION_ID"
fi

# Increment turn count and create Turn span
TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TURN_COUNT=${TURN_COUNT:-0}
TURN_COUNT=$((TURN_COUNT + 1))

# On the first user prompt, backfill the root span's input with that prompt
# (the root may have been created by SessionStart before any prompt was known).
if [ "$TURN_COUNT" = "1" ] && [ -n "$PROMPT" ]; then
    ROOT_UPDATE=$(jq -n --arg id "$ROOT_SPAN_ID" --arg prompt "$PROMPT" \
        '{id:$id, _is_merge:true, input:$prompt}')
    insert_span "$PROJECT_ID" "$ROOT_UPDATE" >/dev/null || true
fi

TURN_SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
START_TIME=$(date +%s)

# Truncate prompt for display (first 100 chars)
PROMPT_PREVIEW="${PROMPT:0:100}"
[ ${#PROMPT} -gt 100 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW}..."

# Create Turn container span (parent is the session span, not the root)
EVENT=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --arg span_id "$TURN_SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg session_span_id "$SESSION_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg prompt "$PROMPT" \
    --argjson turn "$TURN_COUNT" \
    --argjson start_time "$START_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$session_span_id],
        created: $created,
        input: $prompt,
        metrics: {
            start: $start_time
        },
        span_attributes: {
            name: ("Turn " + ($turn | tostring)),
            type: "task"
        }
    }')

ROW_ID=$(insert_span "$PROJECT_ID" "$EVENT") || { log "ERROR" "Failed to create turn span"; exit 0; }

# Save turn state (including per-turn history so session_end.sh can
# attach backfilled LLM spans to the right turn by timestamp).
set_session_state "$SESSION_ID" "turn_count" "$TURN_COUNT"
set_session_state "$SESSION_ID" "current_turn_span_id" "$TURN_SPAN_ID"
set_session_state "$SESSION_ID" "current_turn_start" "$START_TIME"
set_session_state "$SESSION_ID" "current_turn_tool_count" "0"
set_session_state "$SESSION_ID" "turn_span_${TURN_COUNT}" "$TURN_SPAN_ID"
set_session_state "$SESSION_ID" "turn_start_${TURN_COUNT}" "$START_TIME"

log "INFO" "Turn $TURN_COUNT started: $TURN_SPAN_ID"

exit 0
