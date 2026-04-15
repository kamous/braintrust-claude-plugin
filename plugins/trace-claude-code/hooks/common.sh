#!/bin/bash
###
# Common utilities for Braintrust Claude Code tracing hooks
###

# Config
export LOG_FILE="$HOME/.claude/state/braintrust_hook.log"
export CACHE_FILE="$HOME/.claude/state/braintrust_cache.json"
export SESSION_STATE_DIR="$HOME/.claude/state/braintrust_sessions"
export DEBUG="${BRAINTRUST_CC_DEBUG:-false}"
export API_KEY="${BRAINTRUST_API_KEY}"
export PROJECT="${BRAINTRUST_CC_PROJECT:-claude-code}"
export APP_URL="${BRAINTRUST_APP_URL:-https://www.braintrust.dev}"

# Parent span configuration (for attaching to an existing trace)
# If either is set, we're attaching to an existing trace
# Each defaults to the other if not set
if [ -n "${CC_PARENT_SPAN_ID:-}" ] && [ -z "${CC_ROOT_SPAN_ID:-}" ]; then
    export CC_ROOT_SPAN_ID="$CC_PARENT_SPAN_ID"
elif [ -n "${CC_ROOT_SPAN_ID:-}" ] && [ -z "${CC_PARENT_SPAN_ID:-}" ]; then
    export CC_PARENT_SPAN_ID="$CC_ROOT_SPAN_ID"
fi
export CC_PARENT_SPAN_ID="${CC_PARENT_SPAN_ID:-}"
export CC_ROOT_SPAN_ID="${CC_ROOT_SPAN_ID:-}"

# Experiment mode configuration
# If CC_EXPERIMENT_ID is set, spans are inserted into the experiment instead of project_logs
export CC_EXPERIMENT_ID="${CC_EXPERIMENT_ID:-}"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$SESSION_STATE_DIR"

# Logging (defined early so other functions can use it)
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }

# Check if a value is truthy (true, 1, yes, on - case insensitive)
is_truthy() {
    local val="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" || "$val" == "on" ]]
}

debug() { is_truthy "$DEBUG" && log "DEBUG" "$1" || true; }

###
# Cache management (shared across sessions, used for API URL and project IDs)
# Uses simple file-based caching - minor races here are harmless (just extra API calls)
###

get_cache_value() {
    local key="$1"
    [ -f "$CACHE_FILE" ] && cat "$CACHE_FILE" | jq -r ".$key // empty" 2>/dev/null || echo ""
}

set_cache_value() {
    local key="$1"
    local value="$2"
    local cache
    cache=$([ -f "$CACHE_FILE" ] && cat "$CACHE_FILE" 2>/dev/null || echo '{}')
    cache=$(echo "$cache" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' 2>/dev/null) || return 0
    local tmp="$CACHE_FILE.tmp.$$"
    echo "$cache" > "$tmp" && mv "$tmp" "$CACHE_FILE"
}

# Resolve API URL via login endpoint (with caching)
resolve_api_url() {
    # Check for explicit override first
    if [ -n "${BRAINTRUST_API_URL:-}" ]; then
        echo "$BRAINTRUST_API_URL"
        return 0
    fi

    # Check cache
    local cached_url
    cached_url=$(get_cache_value "api_url")
    if [ -n "$cached_url" ]; then
        echo "$cached_url"
        return 0
    fi

    # Login to discover API URL
    if [ -z "$API_KEY" ]; then
        echo "https://api.braintrust.dev"
        return 0
    fi

    local resp
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" "$APP_URL/api/apikey/login" 2>/dev/null) || true

    local api_url
    local org_name="${BRAINTRUST_ORG_NAME:-}"

    if [ -n "$org_name" ]; then
        # Filter by org name if specified
        api_url=$(echo "$resp" | jq -r --arg name "$org_name" \
            '.org_info[] | select(.name == $name) | .api_url // empty' 2>/dev/null | head -1)
    else
        # Use first org
        api_url=$(echo "$resp" | jq -r '.org_info[0].api_url // empty' 2>/dev/null)
    fi

    if [ -n "$api_url" ]; then
        set_cache_value "api_url" "$api_url"
        echo "$api_url"
        return 0
    fi

    # Fall back to default
    echo "https://api.braintrust.dev"
}

# Initialize API_URL (call resolve_api_url lazily when needed)
get_api_url() {
    if [ -z "${_RESOLVED_API_URL:-}" ]; then
        _RESOLVED_API_URL=$(resolve_api_url)
    fi
    echo "$_RESOLVED_API_URL"
}

# Check if tracing is enabled
tracing_enabled() {
    is_truthy "$TRACE_TO_BRAINTRUST"
}

# Validate requirements
check_requirements() {
    for cmd in jq curl uuidgen; do
        command -v "$cmd" &>/dev/null || { log "ERROR" "$cmd not installed"; return 1; }
    done
    [ -z "$API_KEY" ] && { log "ERROR" "BRAINTRUST_API_KEY not set"; return 1; }
    return 0
}

# Get or create project ID (cached per project name)
get_project_id() {
    local name="$1"
    local cache_key="project_id_$name"

    # Check cache first
    local cached_id
    cached_id=$(get_cache_value "$cache_key")
    if [ -n "$cached_id" ]; then
        echo "$cached_id"
        return 0
    fi

    local encoded_name
    encoded_name=$(printf '%s' "$name" | jq -sRr @uri)

    # Try to get existing project
    local api_url
    api_url=$(get_api_url)
    local resp
    resp=$(curl -sf -H "Authorization: Bearer $API_KEY" "$api_url/v1/project?project_name=$encoded_name" 2>/dev/null) || true
    local pid
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    # Create project
    debug "Creating project: $name"
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "{\"name\": \"$name\"}" "$api_url/v1/project" 2>/dev/null) || true
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    return 1
}

# Check if we're in experiment mode
is_experiment_mode() {
    [ -n "$CC_EXPERIMENT_ID" ]
}

# Get the insert endpoint URL based on mode (experiment vs project_logs)
get_insert_endpoint() {
    local object_id="$1"
    local api_url
    api_url=$(get_api_url)

    if is_experiment_mode; then
        echo "$api_url/v1/experiment/$CC_EXPERIMENT_ID/insert"
    else
        echo "$api_url/v1/project_logs/$object_id/insert"
    fi
}

# Insert a span to Braintrust
# In experiment mode, project_id is ignored and CC_EXPERIMENT_ID is used instead
insert_span() {
    local project_id="$1"
    local event_json="$2"

    debug "Inserting span: $(echo "$event_json" | jq -c '.')"

    # Check if API_KEY is set
    if [ -z "$API_KEY" ]; then
        log "ERROR" "API_KEY is empty - check BRAINTRUST_API_KEY env var"
        return 1
    fi

    local endpoint
    endpoint=$(get_insert_endpoint "$project_id")
    debug "Insert endpoint: $endpoint"

    local resp http_code
    # Use -w to capture HTTP status, don't use -f so we can see error responses
    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"events\": [$event_json]}" \
        "$endpoint" 2>&1)

    # Extract HTTP code from last line
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log "ERROR" "Insert failed (HTTP $http_code) to $endpoint: $resp"
        return 1
    fi

    local row_id
    row_id=$(echo "$resp" | jq -r '.row_ids[0] // empty' 2>/dev/null)

    if [ -n "$row_id" ]; then
        echo "$row_id"
        return 0
    else
        log "WARN" "Insert returned empty row_ids: $resp"
        return 1
    fi
}

###
# Per-session state management
# Each session has its own state file: $SESSION_STATE_DIR/{session_id}.json
# This eliminates race conditions between sessions entirely.
###

# Get the state file path for a session
get_session_state_file() {
    local session_id="$1"
    echo "$SESSION_STATE_DIR/${session_id}.json"
}

# Get a value from session state
get_session_state() {
    local session_id="$1"
    local key="$2"
    local state_file
    state_file=$(get_session_state_file "$session_id")
    [ -f "$state_file" ] && cat "$state_file" | jq -r ".$key // empty" 2>/dev/null || echo ""
}

# Set a value in session state
set_session_state() {
    local session_id="$1"
    local key="$2"
    local value="$3"
    local state_file state
    state_file=$(get_session_state_file "$session_id")
    state=$([ -f "$state_file" ] && cat "$state_file" || echo '{}')
    state=$(echo "$state" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
    echo "$state" > "$state_file"
}

# Atomic check-and-set for session state - returns 0 if set, 1 if already exists
# Uses mkdir as an atomic lock for the specific session
check_and_set_session_state() {
    local session_id="$1"
    local key="$2"
    local value="$3"
    local state_file lock_dir
    state_file=$(get_session_state_file "$session_id")
    lock_dir="${state_file}.lock"

    # Try to acquire lock for this specific session
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Another process is initializing this session, wait briefly and check
        sleep 0.1
        local existing
        existing=$(get_session_state "$session_id" "$key")
        if [ -n "$existing" ]; then
            echo "$existing"
            return 1
        fi
        # Lock was released but key still not set - try again
        rmdir "$lock_dir" 2>/dev/null || true
        if ! mkdir "$lock_dir" 2>/dev/null; then
            # Still can't get lock, just check and return
            existing=$(get_session_state "$session_id" "$key")
            if [ -n "$existing" ]; then
                echo "$existing"
                return 1
            fi
        fi
    fi

    # We have the lock - check if key already exists
    local existing
    existing=$(get_session_state "$session_id" "$key")
    if [ -n "$existing" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
        echo "$existing"
        return 1
    fi

    # Set the value
    set_session_state "$session_id" "$key" "$value"
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}

# Clean up old session state files (call periodically or from session_stop)
cleanup_old_sessions() {
    local max_age_hours="${1:-24}"
    local max_age_minutes=$((max_age_hours * 60))
    find "$SESSION_STATE_DIR" -name "*.json" -mmin "+$max_age_minutes" -delete 2>/dev/null || true
    find "$SESSION_STATE_DIR" -name "*.lock" -mmin "+5" -delete 2>/dev/null || true
}

# Generate a UUID
generate_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# Get current ISO timestamp (millisecond precision when python3 is available)
get_timestamp() {
    python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.")+f"{datetime.now(timezone.utc).microsecond//1000:03d}Z")' 2>/dev/null \
        || gdate -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null \
        || date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Maximum bytes to keep for tool input/output payloads before truncating.
# Braintrust has per-event size limits; large Read/Bash outputs can bloat traces quickly.
export BRAINTRUST_CC_MAX_PAYLOAD_BYTES="${BRAINTRUST_CC_MAX_PAYLOAD_BYTES:-16384}"

# Truncate a JSON payload if its serialized length exceeds the configured budget.
# Inputs/outputs are replaced with {_truncated:true, original_bytes:N, preview:"..."}.
# Always returns valid compact JSON on stdout.
truncate_json_payload() {
    local json="$1"
    [ -z "$json" ] && { echo "{}"; return; }
    local len="${#json}"
    if [ "$len" -le "$BRAINTRUST_CC_MAX_PAYLOAD_BYTES" ]; then
        printf '%s' "$json"
        return
    fi
    local preview_len=$((BRAINTRUST_CC_MAX_PAYLOAD_BYTES / 4))
    [ "$preview_len" -gt 2048 ] && preview_len=2048
    local preview="${json:0:$preview_len}"
    jq -cn --arg preview "$preview" --argjson bytes "$len" \
        '{_truncated:true, original_bytes:$bytes, preview:$preview}' 2>/dev/null \
        || echo '{"_truncated":true}'
}

# Get epoch seconds with sub-second precision (float). Falls back to integer seconds.
get_epoch() {
    python3 -c 'import time;print(f"{time.time():.3f}")' 2>/dev/null \
        || gdate +%s.%3N 2>/dev/null \
        || date +%s
}

# Convert ISO timestamp (UTC with Z suffix) to Unix epoch seconds (float with ms precision).
# Preserving sub-second precision matters: without it, LLM spans derived from transcript
# timestamps (int sec) get ordered before tool spans recorded via get_epoch (float sec),
# even when the tool actually executed between two LLM calls.
iso_to_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { get_epoch; return; }
    local ms="000"
    if [[ "$ts" =~ \.([0-9]+)Z?$ ]]; then
        ms="${BASH_REMATCH[1]}000"
        ms="${ms:0:3}"
    fi
    # Strip trailing Z and optional .xxx, then append UTC offset
    local clean_ts="${ts%Z}"
    clean_ts="${clean_ts%.*}"
    clean_ts="${clean_ts}+0000"
    local sec
    sec=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_ts" "+%s" 2>/dev/null \
          || date -d "$ts" "+%s" 2>/dev/null \
          || date +%s)
    echo "${sec}.${ms}"
}

###
# Parse a Claude Code transcript jsonl and emit one Braintrust LLM span per LLM call,
# attached to $parent_span_id. Tracks progress via session state key $last_line_key so
# repeat invocations (stop hooks across turns) don't re-emit the same calls.
#
# Used by both stop_hook.sh (main transcript, parent=Turn span) and subagent_stop.sh
# (sub-agent transcript, parent=Agent span).
###
emit_llm_spans_for_transcript() {
    local conv_file="$1"
    local parent_span_id="$2"
    local last_line_key="$3"
    local session_id="$4"
    local project_id="$5"
    local root_span_id="$6"

    [ -z "$conv_file" ] || [ ! -f "$conv_file" ] && return 0
    [ -z "$parent_span_id" ] || [ -z "$project_id" ] && return 0

    local last_line
    last_line=$(get_session_state "$session_id" "$last_line_key")
    last_line=${last_line:-0}

    local total_lines
    total_lines=$(wc -l < "$conv_file" | tr -d ' ')

    local llm_calls_created=0
    local current_output="" current_tool_calls="[]" current_model=""
    local current_prompt_tokens=0 current_completion_tokens=0
    local current_cached=0 current_cache_create=0
    local current_start="" current_end=""
    local line_num=0
    local history="[]"

    _add_history() {
        local role="$1" content="$2" tool_id="$3" tool_calls="$4"
        if [ "$role" = "tool" ]; then
            history=$(echo "$history" | jq --arg r "$role" --arg c "$content" --arg i "$tool_id" \
                '. += [{role:$r, tool_call_id:$i, content:$c}]')
        elif [ -n "$tool_calls" ] && [ "$tool_calls" != "[]" ]; then
            history=$(echo "$history" | jq --arg r "$role" --arg c "$content" --argjson tc "$tool_calls" \
                '. += [{role:$r, content:$c, tool_calls:$tc}]')
        else
            history=$(echo "$history" | jq --arg r "$role" --arg c "$content" \
                '. += [{role:$r, content:$c}]')
        fi
    }

    _emit_span() {
        local text="$1" model="$2" prompt="$3" comp="$4" start_ts="$5" end_ts="$6" tc="$7" hist="$8" cached="$9" cache_create="${10}"
        [ -z "$text" ] && [ "$tc" = "[]" ] && return 0

        local span_id total_tokens start_time end_time output_json has_tc
        span_id=$(generate_uuid)
        total_tokens=$((prompt + comp))
        start_time=$(iso_to_epoch "$start_ts")
        end_time=$(iso_to_epoch "$end_ts")

        has_tc=$(echo "$tc" | jq 'length > 0' 2>/dev/null)
        if [ "$has_tc" = "true" ]; then
            output_json=$(jq -n --arg c "${text:-}" --argjson tc "$tc" '{role:"assistant", content:$c, tool_calls:$tc}')
        else
            output_json=$(jq -n --arg c "$text" '{role:"assistant", content:$c}')
        fi

        local event
        event=$(jq -n \
            --arg id "$span_id" \
            --arg root "$root_span_id" \
            --arg parent "$parent_span_id" \
            --arg created "${start_ts:-$(get_timestamp)}" \
            --argjson input "$hist" \
            --argjson output "$output_json" \
            --arg model "${model:-claude}" \
            --argjson prompt_tokens "$prompt" \
            --argjson completion_tokens "$comp" \
            --argjson cached_tokens "$cached" \
            --argjson cache_creation_tokens "$cache_create" \
            --argjson tokens "$total_tokens" \
            --argjson start_time "$start_time" \
            --argjson end_time "$end_time" \
            '{
                id:$id, span_id:$id, root_span_id:$root,
                span_parents:[$parent], created:$created,
                input:$input, output:$output,
                metrics:{
                    start:$start_time, end:$end_time,
                    prompt_tokens:$prompt_tokens,
                    completion_tokens:$completion_tokens,
                    prompt_cached_tokens:$cached_tokens,
                    prompt_cache_creation_tokens:$cache_creation_tokens,
                    tokens:$tokens
                },
                metadata:{model:$model},
                span_attributes:{name:$model, type:"llm"}
            }')

        insert_span "$project_id" "$event" >/dev/null && {
            llm_calls_created=$((llm_calls_created + 1))
            log "INFO" "LLM span: $model tokens=$total_tokens (parent=$parent_span_id)"
        } || true
    }

    local line msg_type msg_ts content is_tool_result text tc has_tc model usage itok otok cr cc trc tuid
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [ "$line_num" -le "$last_line" ] && continue
        [ -z "$line" ] && continue

        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        msg_ts=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)

        if [ "$msg_type" = "user" ]; then
            content=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)
            is_tool_result=$(echo "$content" | jq -e '.[0].type == "tool_result"' >/dev/null 2>&1 && echo true || echo false)

            if [ "$is_tool_result" = "true" ]; then
                if [ -n "$current_output" ] || [ "$current_tool_calls" != "[]" ]; then
                    _emit_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$current_start" "$current_end" "$current_tool_calls" "$history" "$current_cached" "$current_cache_create"
                    _add_history "assistant" "$current_output" "" "$current_tool_calls"
                fi
                trc=$(echo "$content" | jq -r '.[0].content // "tool result"' 2>/dev/null)
                tuid=$(echo "$content" | jq -r '.[0].tool_use_id // ""' 2>/dev/null)
                _add_history "tool" "$trc" "$tuid" ""
                current_output=""; current_tool_calls="[]"; current_model=""
                current_prompt_tokens=0; current_completion_tokens=0
                current_cached=0; current_cache_create=0
                current_start="$msg_ts"; current_end=""
            else
                if [ -n "$current_output" ] || [ "$current_tool_calls" != "[]" ]; then
                    _emit_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$current_start" "$current_end" "$current_tool_calls" "$history" "$current_cached" "$current_cache_create"
                    _add_history "assistant" "$current_output" "" "$current_tool_calls"
                fi
                _add_history "user" "$content" "" ""
                current_output=""; current_tool_calls="[]"; current_model=""
                current_prompt_tokens=0; current_completion_tokens=0
                current_cached=0; current_cache_create=0
                current_start="$msg_ts"; current_end=""
            fi

        elif [ "$msg_type" = "assistant" ]; then
            text=$(echo "$line" | jq -r '.message.content | if type=="array" then [.[]|select(.type=="text")|.text]|join("\n") elif type=="string" then . else empty end' 2>/dev/null)
            tc=$(echo "$line" | jq -c '.message.content | if type=="array" then [.[]|select(.type=="tool_use")|{id:.id, type:"function", function:{name:.name, arguments:(.input|tojson)}}] else [] end' 2>/dev/null)
            has_tc=$(echo "$tc" | jq 'length > 0' 2>/dev/null)

            [ -z "$current_start" ] && current_start="$msg_ts"

            if [ -n "$text" ]; then
                if [ -n "$current_output" ]; then
                    current_output="$current_output"$'\n'"$text"
                else
                    current_output="$text"
                fi
                current_end="$msg_ts"
            fi
            if [ "$has_tc" = "true" ]; then
                current_tool_calls="$tc"
                current_end="$msg_ts"
            fi

            model=$(echo "$line" | jq -r '.message.model // empty' 2>/dev/null)
            [ -n "$model" ] && current_model="$model"

            usage=$(echo "$line" | jq -c '.message.usage // {}' 2>/dev/null)
            if [ "$usage" != "{}" ] && [ -n "$usage" ]; then
                itok=$(echo "$usage" | jq -r '.input_tokens // 0' 2>/dev/null)
                otok=$(echo "$usage" | jq -r '.output_tokens // 0' 2>/dev/null)
                cr=$(echo "$usage" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
                cc=$(echo "$usage" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
                [ "$itok" != "null" ] && [ "$itok" -gt 0 ] 2>/dev/null && current_prompt_tokens=$((current_prompt_tokens + itok))
                [ "$otok" != "null" ] && [ "$otok" -gt 0 ] 2>/dev/null && current_completion_tokens=$((current_completion_tokens + otok))
                if [ "$cr" != "null" ] && [ "$cr" -gt 0 ] 2>/dev/null; then
                    current_cached=$((current_cached + cr))
                    current_prompt_tokens=$((current_prompt_tokens + cr))
                fi
                if [ "$cc" != "null" ] && [ "$cc" -gt 0 ] 2>/dev/null; then
                    current_cache_create=$((current_cache_create + cc))
                    current_prompt_tokens=$((current_prompt_tokens + cc))
                fi
            fi
        fi
    done < "$conv_file"

    if [ -n "$current_output" ] || [ "$current_tool_calls" != "[]" ]; then
        _emit_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$current_start" "$current_end" "$current_tool_calls" "$history" "$current_cached" "$current_cache_create"
    fi

    local final_line="${line_num:-0}"
    [ "$final_line" -lt "$total_lines" ] 2>/dev/null && final_line="$total_lines"
    set_session_state "$session_id" "$last_line_key" "$final_line"

    [ "$llm_calls_created" -gt 0 ] && log "INFO" "Emitted $llm_calls_created LLM spans (parent=$parent_span_id)"
    return 0
}

# Get system info for metadata
get_hostname() {
    hostname 2>/dev/null || echo "unknown"
}

get_username() {
    whoami 2>/dev/null || echo "unknown"
}

get_os() {
    uname -s 2>/dev/null || echo "unknown"
}
