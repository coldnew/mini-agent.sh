#!/usr/bin/env bash
set -euo pipefail

# Minimal tool-calling agent (RAM-only memory, no skills, no MCP).
# Requirements: bash, curl, jq
# Env:
#   OPENAI_API_KEY (required)
#   MODEL           (optional, default: gpt-4o-mini)
#   BASE_URL        (optional, default: https://api.openai.com/v1)

MODEL="${MODEL:-gpt-4o-mini}"
BASE_URL="${BASE_URL:-https://api.openai.com/v1}"
MAX_ITERS="${MAX_ITERS:-8}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Error: OPENAI_API_KEY is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl not found" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found" >&2
  exit 1
fi

TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read a text file. Output may be truncated.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"}
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Write text content to a file (overwrite).",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "content": {"type": "string"}
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "exec",
      "description": "Execute a shell command and return stdout/stderr.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string"},
          "working_dir": {"type": "string"}
        },
        "required": ["command"]
      }
    }
  }
]'

SYSTEM_PROMPT=$(cat <<'TXT'
You are a minimal CLI coding assistant.
Use tools when needed.
When calling tools, be precise and safe.
TXT
)

MESSAGES='[]'

append_message() {
  local msg_json="$1"
  MESSAGES=$(jq -c --argjson m "$msg_json" '. + [$m]' <<<"$MESSAGES")
}

run_read_file() {
  local args_json="$1"
  local path
  path=$(jq -r '.path // empty' <<<"$args_json")
  if [[ -z "$path" ]]; then
    printf '%s' "Error: missing path"
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    printf '%s' "Error: file not found: $path"
    return 0
  fi
  local out
  out=$(cat -- "$path" 2>&1 || true)
  if (( ${#out} > 12000 )); then
    out="${out:0:12000}\n...[truncated]"
  fi
  printf '%s' "$out"
}

run_write_file() {
  local args_json="$1"
  local path content dir
  path=$(jq -r '.path // empty' <<<"$args_json")
  content=$(jq -r '.content // empty' <<<"$args_json")
  if [[ -z "$path" ]]; then
    printf '%s' "Error: missing path"
    return 0
  fi
  dir=$(dirname -- "$path")
  mkdir -p -- "$dir"
  printf '%s' "$content" > "$path"
  printf '%s' "Written: $path"
}

run_exec() {
  local args_json="$1"
  local cmd wd
  cmd=$(jq -r '.command // empty' <<<"$args_json")
  wd=$(jq -r '.working_dir // ""' <<<"$args_json")
  if [[ -z "$cmd" ]]; then
    printf '%s' "Error: missing command"
    return 0
  fi

  local lower
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$cmd")
  if grep -Eq '(^|[[:space:];|&])(rm[[:space:]]+-[rf]{1,2}|mkfs|dd[[:space:]]+if=|shutdown|reboot|poweroff)($|[[:space:]])' <<<"$lower"; then
    printf '%s' "Error: command blocked by safety policy"
    return 0
  fi

  local output
  if [[ -n "$wd" ]]; then
    output=$(timeout 30s bash -lc "cd -- $(printf '%q' "$wd") && $cmd" 2>&1 || true)
  else
    output=$(timeout 30s bash -lc "$cmd" 2>&1 || true)
  fi

  if [[ -z "$output" ]]; then
    output="(no output)"
  fi
  if (( ${#output} > 12000 )); then
    output="${output:0:12000}\n...[truncated]"
  fi
  printf '%s' "$output"
}

run_tool() {
  local name="$1"
  local args_json="$2"
  case "$name" in
    read_file)  run_read_file "$args_json" ;;
    write_file) run_write_file "$args_json" ;;
    exec)       run_exec "$args_json" ;;
    *)          printf '%s' "Error: unknown tool: $name" ;;
  esac
}

call_model() {
  local req
  req=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --argjson msgs "$MESSAGES" \
    --argjson tools "$TOOLS_JSON" \
    '{
      model: $model,
      messages: ([{role:"system", content:$system}] + $msgs),
      tools: $tools,
      tool_choice: "auto",
      stream: false
    }')

  curl -sS "$BASE_URL/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$req"
}

run_turn() {
  local user_text="$1"
  append_message "$(jq -n --arg t "$user_text" '{role:"user", content:$t}')"

  local iter
  for ((iter=1; iter<=MAX_ITERS; iter++)); do
    local resp
    resp=$(call_model)

    if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
      echo "Error: model returned non-JSON response" >&2
      echo "$resp" >&2
      return 1
    fi

    if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
      echo "API error: $(jq -r '.error.message // .error // "unknown error"' <<<"$resp")" >&2
      return 1
    fi

    local assistant
    assistant=$(jq -c '.choices[0].message' <<<"$resp")
    append_message "$assistant"

    local tool_count
    tool_count=$(jq -r '(.choices[0].message.tool_calls // []) | length' <<<"$resp")

    if [[ "$tool_count" == "0" ]]; then
      jq -r '.choices[0].message.content // ""' <<<"$resp"
      return 0
    fi

    local i
    for ((i=0; i<tool_count; i++)); do
      local tc_id tc_name tc_args result
      tc_id=$(jq -r ".choices[0].message.tool_calls[$i].id" <<<"$resp")
      tc_name=$(jq -r ".choices[0].message.tool_calls[$i].function.name" <<<"$resp")
      tc_args=$(jq -r ".choices[0].message.tool_calls[$i].function.arguments" <<<"$resp")

      if ! jq -e . >/dev/null 2>&1 <<<"$tc_args"; then
        result="Error: tool arguments are not valid JSON"
      else
        echo "[tool] $tc_name $tc_args" >&2
        result=$(run_tool "$tc_name" "$tc_args")
      fi

      append_message "$(jq -n \
        --arg id "$tc_id" \
        --arg name "$tc_name" \
        --arg content "$result" \
        '{role:"tool", tool_call_id:$id, name:$name, content:$content}')"
    done
  done

  echo "Error: reached MAX_ITERS=$MAX_ITERS without final assistant text" >&2
  return 1
}

print_help() {
  cat <<'TXT'
Commands:
  /help   Show help
  /clear  Clear in-RAM conversation history
  /quit   Exit
TXT
}

main() {
  if (( $# > 0 )); then
    run_turn "$*"
    return
  fi

  echo "mini_agent.sh - model: $MODEL"
  echo "Type /help for commands."

  local line
  while true; do
    printf 'You: '
    if ! IFS= read -r line; then
      echo
      break
    fi

    case "$line" in
      "") continue ;;
      /quit|/exit) break ;;
      /help) print_help; continue ;;
      /clear) MESSAGES='[]'; echo "(cleared)"; continue ;;
    esac

    if ! run_turn "$line"; then
      echo "(turn failed)" >&2
    fi
  done
}

main "$@"
