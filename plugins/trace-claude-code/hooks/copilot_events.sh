#!/bin/bash
###
# Copilot CLI events.jsonl → Braintrust span emitter
#
# Copilot hook payloads are information-poor: no model, no tokens, no
# sub-agent internal calls. The full session timeline lives at
#   ~/.copilot/session-state/<native-session-id>/events.jsonl
# with assistant.message (LLM calls), tool.execution_* (tool timings),
# subagent.started/completed (agent metrics + model), and session.model_change.
# We parse that file at session_end to backfill:
#   - Sub-agent internal tool spans (parented to their Agent span)
#   - Sub-agent LLM spans (parented to their Agent span)
#   - Main-session LLM spans (parented to the Turn span covering the timestamp)
#   - Agent span metric merge (model / totalTokens / durationMs)
###

# Find the Copilot native session-state directory whose session.start.cwd
# matches the given cwd and whose startTime is closest to (but not after)
# our Braintrust session start.
copilot_find_native_session_dir() {
    local want_cwd="$1"
    local base="${HOME}/.copilot/session-state"
    [ -d "$base" ] || { echo ""; return; }

    local best_dir=""
    local best_mtime=0
    local d events_file start_cwd mtime
    for d in "$base"/*/; do
        events_file="${d}events.jsonl"
        [ -f "$events_file" ] || continue
        start_cwd=$(head -1 "$events_file" 2>/dev/null | jq -r 'select(.type=="session.start") | .data.context.cwd // empty' 2>/dev/null)
        [ "$start_cwd" = "$want_cwd" ] || continue
        mtime=$(stat -f %m "$events_file" 2>/dev/null || stat -c %Y "$events_file" 2>/dev/null)
        if [ "${mtime:-0}" -gt "$best_mtime" ]; then
            best_mtime=$mtime
            best_dir="$d"
        fi
    done
    echo "${best_dir%/}"
}

# Emit LLM/sub-agent-tool/agent-merge spans by parsing events.jsonl.
# Idempotent: marks session as processed to avoid duplicates.
#
# Args: $1=session_id $2=project_id $3=root_span_id
emit_copilot_event_spans() {
    local session_id="$1"
    local project_id="$2"
    local root_span_id="$3"

    local cwd; cwd=$(get_session_state "$session_id" "cwd")
    [ -z "$cwd" ] && { debug "No cwd recorded; cannot locate Copilot native session"; return 0; }

    local native_dir; native_dir=$(copilot_find_native_session_dir "$cwd")
    local events_file="${native_dir}/events.jsonl"
    if [ ! -f "$events_file" ]; then
        debug "Copilot events.jsonl not found under cwd=$cwd"
        return 0
    fi

    # Incremental parse: skip lines before the cursor (last byte offset processed).
    # Lets us run on every Stop hook without duplicate emission, even when
    # sessionEnd never fires (Copilot does not always emit it).
    local cursor; cursor=$(get_session_state "$session_id" "copilot_events_cursor")
    cursor=${cursor:-0}
    local file_size; file_size=$(wc -c < "$events_file" 2>/dev/null | tr -d ' ')
    if [ "${file_size:-0}" -le "$cursor" ]; then
        debug "Copilot events: nothing new since cursor=$cursor (size=$file_size)"
        return 0
    fi
    log "INFO" "Parsing Copilot events.jsonl from offset $cursor: $events_file"

    # 1) Pre-scan: build auxiliary maps.
    # toolCallId → agent_name (only for "task" tool requests)
    local tcid_agent_map
    tcid_agent_map=$(jq -c -s '
        map(select(.type=="assistant.message") | .data.toolRequests // []) | add // []
        | map(select(.name=="task")) | map({ (.toolCallId): (.arguments.name // "") }) | add // {}
    ' "$events_file" 2>/dev/null)
    [ -z "$tcid_agent_map" ] && tcid_agent_map='{}'

    # task toolCallId → model (from subagent.completed events — each sub-agent
    # often runs a cheaper model than the main session, so session.model_change
    # is not sufficient).
    local agent_model_map
    agent_model_map=$(jq -c -s '
        [.[] | select(.type=="subagent.completed") | {(.data.toolCallId): (.data.model // "")}] | add // {}
    ' "$events_file" 2>/dev/null)
    [ -z "$agent_model_map" ] && agent_model_map='{}'

    # Build turn timeline from our session state.
    local turn_count; turn_count=$(get_session_state "$session_id" "turn_count")
    turn_count=${turn_count:-0}
    local turn_timeline='[]'
    local i turn_span turn_start
    for ((i=1; i<=turn_count; i++)); do
        turn_span=$(get_session_state "$session_id" "turn_span_${i}")
        turn_start=$(get_session_state "$session_id" "turn_start_${i}")
        [ -z "$turn_span" ] && continue
        turn_timeline=$(echo "$turn_timeline" | jq -c --arg span "$turn_span" --argjson start "${turn_start:-0}" '. + [{span:$span, start:$start}]')
    done

    # 2) Walk events in order. Track per-lane "last end ts" to compute LLM
    # span durations: main LLM starts after the preceding turn_start or
    # tool_complete; sub-agent LLM starts after subagent.started or its
    # preceding child tool_complete.
    # State persisted across Stop hooks (incremental parse).
    local current_model; current_model=$(get_session_state "$session_id" "copilot_current_model")
    local tool_start_map; tool_start_map=$(get_session_state "$session_id" "copilot_tool_start_map")
    [ -z "$tool_start_map" ] && tool_start_map='{}'
    local last_end_main; last_end_main=$(get_session_state "$session_id" "copilot_last_end_main")
    last_end_main=${last_end_main:-0}
    local last_end_agent; last_end_agent=$(get_session_state "$session_id" "copilot_last_end_agent")
    [ -z "$last_end_agent" ] && last_end_agent='{}'

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local etype ets_iso ets
        etype=$(echo "$line" | jq -r '.type // empty')
        ets_iso=$(echo "$line" | jq -r '.timestamp // empty')
        ets=$(iso_to_epoch "$ets_iso" 2>/dev/null)
        [ -z "$ets" ] && ets=0

        case "$etype" in
            session.model_change)
                current_model=$(echo "$line" | jq -r '.data.newModel // empty')
                ;;
            assistant.turn_start)
                last_end_main="$ets"
                ;;
            subagent.started)
                local sa_tcid; sa_tcid=$(echo "$line" | jq -r '.data.toolCallId // empty')
                [ -n "$sa_tcid" ] && last_end_agent=$(echo "$last_end_agent" | jq -c --arg k "$sa_tcid" --argjson v "$ets" '.[$k] = $v')
                ;;
            assistant.message)
                local parent_tcid model_for_msg start_ts
                parent_tcid=$(echo "$line" | jq -r '.data.parentToolCallId // empty')
                if [ -n "$parent_tcid" ]; then
                    model_for_msg=$(echo "$agent_model_map" | jq -r --arg k "$parent_tcid" '.[$k] // empty')
                    [ -z "$model_for_msg" ] && model_for_msg="$current_model"
                    start_ts=$(echo "$last_end_agent" | jq -r --arg k "$parent_tcid" '.[$k] // empty')
                    [ -z "$start_ts" ] && start_ts="$ets"
                    # Advance the per-agent cursor past this LLM call.
                    last_end_agent=$(echo "$last_end_agent" | jq -c --arg k "$parent_tcid" --argjson v "$ets" '.[$k] = $v')
                else
                    model_for_msg="$current_model"
                    start_ts="$last_end_main"
                    [ "$start_ts" = "0" ] && start_ts="$ets"
                    last_end_main="$ets"
                fi
                _copilot_emit_llm_span "$line" "$ets" "$start_ts" "$model_for_msg" "$session_id" "$project_id" "$root_span_id" "$tcid_agent_map" "$turn_timeline"
                ;;
            tool.execution_start)
                local tcid pcid tname args
                tcid=$(echo "$line" | jq -r '.data.toolCallId // empty')
                pcid=$(echo "$line" | jq -r '.data.parentToolCallId // empty')
                tname=$(echo "$line" | jq -r '.data.toolName // empty')
                args=$(echo "$line" | jq -c '.data.arguments // {}')
                tool_start_map=$(echo "$tool_start_map" | jq -c --arg id "$tcid" --argjson start "$ets" --arg parent "$pcid" --arg name "$tname" --argjson args "$args" '.[$id] = {start:$start, parent:$parent, name:$name, args:$args}')
                ;;
            tool.execution_complete)
                local c_tcid c_pcid
                c_tcid=$(echo "$line" | jq -r '.data.toolCallId // empty')
                c_pcid=$(echo "$line" | jq -r '.data.parentToolCallId // empty')
                if [ -n "$c_pcid" ]; then
                    last_end_agent=$(echo "$last_end_agent" | jq -c --arg k "$c_pcid" --argjson v "$ets" '.[$k] = $v')
                else
                    last_end_main="$ets"
                fi
                _copilot_emit_subagent_tool_span "$line" "$ets" "$session_id" "$project_id" "$root_span_id" "$tool_start_map" "$tcid_agent_map"
                ;;
            subagent.completed)
                _copilot_merge_subagent_metrics "$line" "$session_id" "$project_id" "$tcid_agent_map"
                ;;
        esac
    done < <(tail -c "+$((cursor + 1))" "$events_file")

    set_session_state "$session_id" "copilot_events_cursor" "$file_size"
    set_session_state "$session_id" "copilot_current_model" "$current_model"
    set_session_state "$session_id" "copilot_tool_start_map" "$tool_start_map"
    set_session_state "$session_id" "copilot_last_end_main" "$last_end_main"
    set_session_state "$session_id" "copilot_last_end_agent" "$last_end_agent"
    log "INFO" "Copilot events parsed up to offset $file_size"
}

# Emit an LLM span from an assistant.message event.
_copilot_emit_llm_span() {
    local line="$1" ets="$2" start_ts="$3" model="$4" session_id="$5" project_id="$6"
    local root_span_id="$7" tcid_agent_map="$8" turn_timeline="$9"

    local parent_tcid content reasoning output_tokens tool_requests msg_id
    parent_tcid=$(echo "$line" | jq -r '.data.parentToolCallId // empty')
    content=$(echo "$line" | jq -r '.data.content // empty')
    reasoning=$(echo "$line" | jq -r '.data.reasoningText // empty')
    output_tokens=$(echo "$line" | jq -r '.data.outputTokens // 0')
    tool_requests=$(echo "$line" | jq -c '.data.toolRequests // []')
    msg_id=$(echo "$line" | jq -r '.data.messageId // empty')

    # Determine parent span: sub-agent message → Agent span; else → Turn span by timestamp.
    local parent_span=""
    if [ -n "$parent_tcid" ]; then
        local agent_name; agent_name=$(echo "$tcid_agent_map" | jq -r --arg k "$parent_tcid" '.[$k] // empty')
        [ -n "$agent_name" ] && parent_span=$(get_session_state "$session_id" "copilot_agent_span_${agent_name}")
    fi
    if [ -z "$parent_span" ]; then
        # find turn whose start <= ets (largest)
        parent_span=$(echo "$turn_timeline" | jq -r --argjson t "$ets" '[.[] | select(.start <= $t)] | last.span // empty')
    fi
    [ -z "$parent_span" ] && parent_span="$root_span_id"

    local span_id; span_id=$(generate_uuid)
    local created; created=$(date -u -r "${ets%.*}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build input: reasoning + any tool-request summary.
    local llm_input; llm_input=$(jq -cn --arg r "$reasoning" --argjson tr "$tool_requests" '{reasoning:$r, tool_requests:$tr}')

    local event
    event=$(jq -n \
        --arg id "$span_id" \
        --arg root "$root_span_id" \
        --arg parent "$parent_span" \
        --arg created "$created" \
        --arg model "$model" \
        --arg msg_id "$msg_id" \
        --argjson input "$llm_input" \
        --arg output "$content" \
        --argjson start "$start_ts" \
        --argjson end "$ets" \
        --argjson out_toks "$output_tokens" \
        '{
            id: $id, span_id: $id,
            root_span_id: $root,
            span_parents: [$parent],
            created: $created,
            input: $input,
            output: $output,
            metrics: { start: $start, end: $end, completion_tokens: $out_toks, tokens: $out_toks },
            metadata: { model: $model, message_id: $msg_id },
            span_attributes: { name: ("LLM: " + $model), type: "llm" }
        }')
    insert_span "$project_id" "$event" >/dev/null || debug "LLM span insert failed"
}

# Emit a tool span for a sub-agent internal tool (parentToolCallId non-empty).
# Main-session tools are already emitted by post_tool_use.sh — skip them here.
_copilot_emit_subagent_tool_span() {
    local line="$1" end_ets="$2" session_id="$3" project_id="$4"
    local root_span_id="$5" tool_start_map="$6" tcid_agent_map="$7"

    local tcid pcid model result success
    tcid=$(echo "$line" | jq -r '.data.toolCallId // empty')
    pcid=$(echo "$line" | jq -r '.data.parentToolCallId // empty')
    model=$(echo "$line" | jq -r '.data.model // empty')
    result=$(echo "$line" | jq -c '.data.result // {}')
    success=$(echo "$line" | jq -r '.data.success // true')

    # Only emit for sub-agent internal tools.
    [ -z "$pcid" ] && return 0

    local start_info; start_info=$(echo "$tool_start_map" | jq -c --arg k "$tcid" '.[$k] // empty')
    [ -z "$start_info" ] || [ "$start_info" = "null" ] && return 0

    local start_ets tname args
    start_ets=$(echo "$start_info" | jq -r '.start')
    tname=$(echo "$start_info" | jq -r '.name')
    args=$(echo "$start_info" | jq -c '.args')

    local agent_name; agent_name=$(echo "$tcid_agent_map" | jq -r --arg k "$pcid" '.[$k] // empty')
    [ -z "$agent_name" ] && return 0
    local parent_span; parent_span=$(get_session_state "$session_id" "copilot_agent_span_${agent_name}")
    [ -z "$parent_span" ] && return 0

    local span_id; span_id=$(generate_uuid)
    local created; created=$(date -u -r "${start_ets%.*}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    local err=""
    [ "$success" != "true" ] && err="tool execution failed"

    local event
    event=$(jq -n \
        --arg id "$span_id" \
        --arg root "$root_span_id" \
        --arg parent "$parent_span" \
        --arg created "$created" \
        --arg tname "$tname" \
        --arg model "$model" \
        --arg tcid "$tcid" \
        --argjson input "$args" \
        --argjson output "$result" \
        --argjson start "$start_ets" \
        --argjson end "$end_ets" \
        --arg err "$err" \
        '{
            id: $id, span_id: $id,
            root_span_id: $root,
            span_parents: [$parent],
            created: $created,
            input: $input,
            output: $output,
            metrics: { start: $start, end: $end },
            metadata: { tool_name: $tname, tool_call_id: $tcid, model: $model, runtime: "copilot" },
            span_attributes: { name: $tname, type: "tool" }
        } + (if $err == "" then {} else {error: $err} end)')
    insert_span "$project_id" "$event" >/dev/null || debug "sub-agent tool span insert failed"
}

# Merge subagent.completed metrics (model, totalTokens, durationMs, totalToolCalls)
# into the Agent span created by post_tool_use.sh.
_copilot_merge_subagent_metrics() {
    local line="$1" session_id="$2" project_id="$3" tcid_agent_map="$4"

    local tcid model total_tokens total_tools duration_ms
    tcid=$(echo "$line" | jq -r '.data.toolCallId // empty')
    model=$(echo "$line" | jq -r '.data.model // empty')
    total_tokens=$(echo "$line" | jq -r '.data.totalTokens // 0')
    total_tools=$(echo "$line" | jq -r '.data.totalToolCalls // 0')
    duration_ms=$(echo "$line" | jq -r '.data.durationMs // 0')

    local agent_name; agent_name=$(echo "$tcid_agent_map" | jq -r --arg k "$tcid" '.[$k] // empty')
    [ -z "$agent_name" ] && return 0
    local agent_span; agent_span=$(get_session_state "$session_id" "copilot_agent_span_${agent_name}")
    [ -z "$agent_span" ] && return 0

    local update
    update=$(jq -n \
        --arg id "$agent_span" \
        --arg model "$model" \
        --argjson tokens "$total_tokens" \
        --argjson tools "$total_tools" \
        --argjson dur_ms "$duration_ms" \
        '{
            id: $id, _is_merge: true,
            metrics: { tokens: $tokens, tool_use_count: $tools, duration_ms: $dur_ms },
            metadata: { model: $model, agent_id: $id }
        }')
    insert_span "$project_id" "$update" >/dev/null || debug "Agent merge failed"
}
