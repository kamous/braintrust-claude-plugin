#!/bin/bash
###
# Claude Code adapter — payload is already in canonical shape.
# Adds the runtime field and normalizes any missing fields to empty strings.
###

_normalize_to_canonical() {
    local raw="$1"
    # Claude payload fields match canonical names directly; just stamp the runtime.
    echo "$raw" | jq -c --arg r "claude" '
        . + {
            runtime: $r,
            tool_name:              (.tool_name // ""),
            tool_input:             (.tool_input // {}),
            tool_response:          (.tool_response // .output // {}),
            agent_id:               (.agent_id // ""),
            agent_type:             (.agent_type // ""),
            transcript_path:        (.transcript_path // ""),
            last_assistant_message: (.last_assistant_message // ""),
            cwd:                    (.cwd // ""),
            prompt:                 (.prompt // "")
        }
    ' 2>/dev/null || echo "$raw"
}
