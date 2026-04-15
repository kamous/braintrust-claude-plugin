#!/bin/bash
###
# Copilot CLI adapter — maps Copilot-native payload to canonical Claude-like shape.
#
# Copilot CLI doesn't include session_id or tool_use_id in hook payloads, so
# we manage them here:
#   - session_id : persisted in a single file keyed by session lifecycle
#   - tool_use_id: NOT synthesized here; pre/post_tool_use.sh coordinate it via
#                  session state (copilot_pending_tool_id) because pre and post
#                  invocations have different timestamps, making hash-based IDs
#                  unreliable without shared state.
#
# Field mapping:
#   toolName   -> tool_name
#   toolArgs   -> tool_input  (object or string wrapped in {command:...})
#   toolResult -> tool_response (object or string wrapped in {output:...})
#   subagentId / agentId     -> agent_id
#   subagentType / agentType -> agent_type
#   lastMessage              -> last_assistant_message
###

_COPILOT_SESSION_FILE="${HOME}/.copilot/.braintrust-session"

_copilot_get_or_init_session_id() {
    local event_hint="$1"
    local session_id

    # Copilot may fire userPromptSubmitted BEFORE sessionStart (task-session
    # architecture). To keep the whole CLI run stitched together, reuse the
    # existing file if it was written within the last 30 min — otherwise treat
    # as stale and rotate. session_end explicitly clears the file.
    if [ -f "$_COPILOT_SESSION_FILE" ]; then
        local mtime now age
        mtime=$(stat -f %m "$_COPILOT_SESSION_FILE" 2>/dev/null || stat -c %Y "$_COPILOT_SESSION_FILE" 2>/dev/null)
        now=$(date +%s)
        age=$(( now - ${mtime:-0} ))
        if [ "$age" -lt 1800 ]; then
            session_id=$(cat "$_COPILOT_SESSION_FILE")
        fi
    fi

    if [ -z "$session_id" ]; then
        session_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || cat /proc/sys/kernel/random/uuid 2>/dev/null)
        mkdir -p "$(dirname "$_COPILOT_SESSION_FILE")"
        echo "$session_id" > "$_COPILOT_SESSION_FILE"
    fi

    [ "$event_hint" = "session_end" ] && rm -f "$_COPILOT_SESSION_FILE" 2>/dev/null || true

    echo "$session_id"
}

_copilot_coerce_json_field() {
    local raw_field="$1"   # raw JSON value from jq
    local string_key="$2"  # wrap key when value is a plain string
    if [ -z "$raw_field" ] || [ "$raw_field" = "null" ]; then
        echo "{}"
    elif echo "$raw_field" | jq -e 'type == "string"' >/dev/null 2>&1; then
        jq -cn --arg v "$raw_field" --arg k "$string_key" '{($k): $v}'
    else
        echo "$raw_field"
    fi
}

_normalize_to_canonical() {
    local raw="$1"
    local event_hint="${2:-}"

    local session_id
    session_id=$(_copilot_get_or_init_session_id "$event_hint")

    # Extract scalar fields
    local tool_name cwd prompt agent_id agent_type last_msg
    tool_name=$(echo "$raw" | jq -r '.toolName // empty' 2>/dev/null)
    cwd=$(echo "$raw" | jq -r '.cwd // empty' 2>/dev/null)
    prompt=$(echo "$raw" | jq -r '.prompt // empty' 2>/dev/null)
    agent_id=$(echo "$raw" | jq -r '.subagentId // .agentId // empty' 2>/dev/null)
    agent_type=$(echo "$raw" | jq -r '.subagentType // .agentType // empty' 2>/dev/null)
    last_msg=$(echo "$raw" | jq -r '.lastMessage // .last_assistant_message // empty' 2>/dev/null)

    # toolArgs / toolResult may be JSON object or plain string
    local raw_args raw_result tool_input tool_response
    raw_args=$(echo "$raw" | jq -c '.toolArgs // empty' 2>/dev/null)
    raw_result=$(echo "$raw" | jq -c '.toolResult // empty' 2>/dev/null)
    tool_input=$(_copilot_coerce_json_field "$raw_args" "command")
    tool_response=$(_copilot_coerce_json_field "$raw_result" "output")

    jq -cn \
        --arg session_id   "$session_id" \
        --arg tool_name    "${tool_name:-}" \
        --argjson tool_input    "${tool_input}" \
        --argjson tool_response "${tool_response}" \
        --arg cwd          "${cwd:-}" \
        --arg prompt       "${prompt:-}" \
        --arg agent_id     "${agent_id:-}" \
        --arg agent_type   "${agent_type:-}" \
        --arg last_msg     "${last_msg:-}" \
        --arg runtime      "copilot" \
        '{
            session_id:               $session_id,
            tool_use_id:              "",
            tool_name:                $tool_name,
            tool_input:               $tool_input,
            tool_response:            $tool_response,
            agent_id:                 $agent_id,
            agent_type:               $agent_type,
            transcript_path:          "",
            last_assistant_message:   $last_msg,
            cwd:                      $cwd,
            prompt:                   $prompt,
            runtime:                  $runtime
        }'
}
