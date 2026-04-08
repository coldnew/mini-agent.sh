#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# mini-agent.sh
# -----------------------------------------------------------------------------
# Minimal tool-calling CLI coding agent:
# - RAM-only conversation memory (no persistence)
# - No skills, no MCP
# - OpenAI-compatible Chat Completions API
#
# Requirements:
#   - bash
#   - curl
#   - jq
#
# Environment variables:
#   OPENAI_API_KEY  Required. API key sent as Bearer token.
#   MODEL           Optional. Default: gpt-4o-mini
#   BASE_URL        Optional. Default: https://api.openai.com/v1
#   MAX_ITERS       Optional. Max tool-call loops per user turn. Default: 8
#
# Usage:
#   Interactive mode:
#     ./mini-agent.sh
#
#   Single-turn mode:
#     ./mini-agent.sh "summarize this repository"
#
#   Show embedded docs:
#     ./mini-agent.sh --help
#     ./mini-agent.sh --docs
#
# Provider examples:
#   OpenAI:
#     OPENAI_API_KEY=<OPENAI_KEY> \
#     BASE_URL=https://api.openai.com/v1 \
#     MODEL=gpt-4o-mini \
#     ./mini-agent.sh
#
#   OpenRouter:
#     OPENAI_API_KEY=<OPENROUTER_API_KEY> \
#     BASE_URL=https://openrouter.ai/api/v1 \
#     MODEL=openrouter/free \
#     ./mini-agent.sh
#
#   Ollama (OpenAI-compatible endpoint):
#     OPENAI_API_KEY=ollama \
#     BASE_URL=http://localhost:11434/v1 \
#     MODEL=llama3.1 \
#     ./mini-agent.sh
#
#   LM Studio (OpenAI-compatible local server):
#     OPENAI_API_KEY=lm-studio \
#     BASE_URL=http://localhost:1234/v1 \
#     MODEL=<loaded-model-id> \
#     ./mini-agent.sh
# -----------------------------------------------------------------------------

# Runtime defaults. These can be overridden by environment variables.
MODEL="${MODEL:-gpt-4o-mini}"
BASE_URL="${BASE_URL:-https://api.openai.com/v1}"
MAX_ITERS="${MAX_ITERS:-8}"

# Operational limits used by tools to keep responses bounded and prevent hangs.
# Keeping these centralized makes behavior explicit and easy to tune.
TOOL_TIMEOUT_SECONDS="${TOOL_TIMEOUT_SECONDS:-30}"
TOOL_MAX_OUTPUT_CHARS="${TOOL_MAX_OUTPUT_CHARS:-12000}"

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

# System prompt intentionally stays short. This script demonstrates tool-loop
# mechanics, so prompt policy remains minimal and easy to inspect.
SYSTEM_PROMPT=$(cat <<'TXT'
You are a minimal CLI coding assistant.
Use tools when needed.
When calling tools, be precise and safe.
TXT
)

MESSAGES='[]'

# -----------------------------------------------------------------------------
# append_message
# -----------------------------------------------------------------------------
# Purpose:
#   Append one JSON message object to the in-memory conversation array.
#
# Input:
#   $1 = JSON object with message shape expected by Chat Completions API.
#
# Behavior:
#   - Uses jq `--argjson` for structural insertion (not string concat),
#     reducing JSON escaping bugs.
#   - Preserves order of conversation turns.
# -----------------------------------------------------------------------------
append_message() {
  local msg_json="$1"
  MESSAGES=$(jq -c --argjson m "$msg_json" '. + [$m]' <<<"$MESSAGES")
}

# -----------------------------------------------------------------------------
# run_read_file
# -----------------------------------------------------------------------------
# Tool implementation for `read_file`.
#
# Input JSON:
#   {"path": "<file path>"}
#
# Output:
#   Plain text string returned to model as tool result.
#
# Design notes:
#   - Returns user-facing error text instead of non-zero exit, so the tool loop
#     can continue and model can recover with a corrected call.
#   - Truncates large files to protect token budget and terminal output size.
# -----------------------------------------------------------------------------
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
  if (( ${#out} > TOOL_MAX_OUTPUT_CHARS )); then
    out="${out:0:TOOL_MAX_OUTPUT_CHARS}\n...[truncated]"
  fi
  printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# run_write_file
# -----------------------------------------------------------------------------
# Tool implementation for `write_file`.
#
# Input JSON:
#   {"path": "<file path>", "content": "<full text content>"}
#
# Output:
#   Status text ("Written: <path>") or validation error text.
#
# Design notes:
#   - Overwrite behavior is explicit and deterministic.
#   - Parent directories are created automatically to simplify model usage.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# run_exec
# -----------------------------------------------------------------------------
# Tool implementation for `exec`.
#
# Input JSON:
#   {"command":"<shell command>", "working_dir":"<optional dir>"}
#
# Output:
#   Combined stdout/stderr text, or validation/safety error text.
#
# Safety model:
#   - Lightweight regex blocklist for obviously destructive commands.
#   - Per-command timeout to avoid hanging the agent loop.
#   - Returns tool text instead of exiting on command failure, allowing the
#     model to inspect failure output and retry with adjustments.
#
# Scope note:
#   This is intentionally a minimal safety layer and not a full sandbox.
# -----------------------------------------------------------------------------
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
    output=$(timeout "${TOOL_TIMEOUT_SECONDS}s" bash -lc "cd -- $(printf '%q' "$wd") && $cmd" 2>&1 || true)
  else
    output=$(timeout "${TOOL_TIMEOUT_SECONDS}s" bash -lc "$cmd" 2>&1 || true)
  fi

  if [[ -z "$output" ]]; then
    output="(no output)"
  fi
  if (( ${#output} > TOOL_MAX_OUTPUT_CHARS )); then
    output="${output:0:TOOL_MAX_OUTPUT_CHARS}\n...[truncated]"
  fi
  printf '%s' "$output"
}

# -----------------------------------------------------------------------------
# run_tool
# -----------------------------------------------------------------------------
# Routes a tool call by name to its implementation.
#
# Behavior:
#   - Only known tools are executable.
#   - Unknown tool names become explicit error text for model recovery.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# require_api_key
# -----------------------------------------------------------------------------
# Validates credentials only for runtime model calls (not for --help/--docs),
# which keeps documentation accessible without environment setup.
# -----------------------------------------------------------------------------
require_api_key() {
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "Error: OPENAI_API_KEY is required." >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# call_model
# -----------------------------------------------------------------------------
# Builds one Chat Completions request from current in-memory state and sends it
# to an OpenAI-compatible endpoint.
#
# Request composition:
#   - Prepends one system message.
#   - Appends conversation messages collected in MESSAGES.
#   - Attaches declared tool schema and enables auto tool choice.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# run_turn
# -----------------------------------------------------------------------------
# Executes one complete user turn.
#
# Loop algorithm:
#   1) Append user message.
#   2) Call model.
#   3) If assistant returned tool_calls:
#      - Execute each tool
#      - Append tool results
#      - Repeat
#   4) If assistant returned normal content, print and finish.
#
# Guardrail:
#   MAX_ITERS prevents infinite tool-call loops on bad prompts or provider bugs.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# print_help
# -----------------------------------------------------------------------------
# Prints embedded documentation and provider setup examples.
# -----------------------------------------------------------------------------
print_help() {
  cat <<'TXT'
mini-agent.sh - Minimal tool-calling CLI coding agent

USAGE
  ./mini-agent.sh
  ./mini-agent.sh "your prompt"
  ./mini-agent.sh --help
  ./mini-agent.sh --docs

REQUIREMENTS
  - bash
  - curl
  - jq

ENVIRONMENT
  OPENAI_API_KEY (required)
  MODEL           (optional, default: gpt-4o-mini)
  BASE_URL        (optional, default: https://api.openai.com/v1)
  MAX_ITERS       (optional, default: 8)

INTERACTIVE COMMANDS
  /help    Show this help
  /clear   Clear in-RAM conversation history
  /quit    Exit (same as /exit)

PROVIDER EXAMPLES
  OpenAI:
    export OPENAI_API_KEY="<OPENAI_KEY>"
    export BASE_URL="https://api.openai.com/v1"
    export MODEL="gpt-4o-mini"
    ./mini-agent.sh

  OpenRouter:
    export OPENAI_API_KEY="<OPENROUTER_API_KEY>"
    export BASE_URL="https://openrouter.ai/api/v1"
    export MODEL="openrouter/free"
    ./mini-agent.sh

  Ollama:
    export OPENAI_API_KEY="ollama"
    export BASE_URL="http://localhost:11434/v1"
    export MODEL="llama3.1"
    ./mini-agent.sh

  LM Studio:
    export OPENAI_API_KEY="lm-studio"
    export BASE_URL="http://localhost:1234/v1"
    export MODEL="<loaded-model-id>"
    ./mini-agent.sh

SAFETY / LIMITS
  - exec tool command timeout: 30s (default)
  - tool output truncation: ~12000 chars (default)
  - blocked patterns include:
    rm -rf, mkfs, dd if=, shutdown, reboot, poweroff
TXT
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
# Entry point:
#   - Handles docs flags early.
#   - Enforces API key requirement for runtime model usage.
#   - Runs single-turn mode when positional args exist.
#   - Otherwise runs interactive REPL loop.
# -----------------------------------------------------------------------------
main() {
  case "${1:-}" in
    -h|--help|--docs)
      print_help
      return
      ;;
  esac

  require_api_key

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
