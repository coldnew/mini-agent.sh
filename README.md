# mini-agent.sh

Minimal Bash tool-calling coding agent with RAM-only chat history.

- Single file: `mini-agent.sh`
- Built-in tools: `read_file`, `write_file`, `exec`
- No persistent memory, no MCP, no skills

## Requirements

- `bash`
- `curl`
- `jq`

## Quick Start

```bash
chmod +x mini-agent.sh
export OPENAI_API_KEY="your_api_key"
./mini-agent.sh
```

Single-turn mode:

```bash
./mini-agent.sh "summarize this repo"
```

## Environment Variables

- `OPENAI_API_KEY` (required)
- `MODEL` (optional, default: `gpt-4o-mini`)
- `BASE_URL` (optional, default: `https://api.openai.com/v1`)
- `MAX_ITERS` (optional, default: `8`)

## Interactive Commands

- `/help` show commands
- `/clear` clear in-memory conversation
- `/quit` (or `/exit`) leave the session

## Provider Setup

This script uses OpenAI-compatible Chat Completions at:

- `POST $BASE_URL/chat/completions`

So switching providers is done by changing `BASE_URL`, `MODEL`, and API key env vars.

### 1) OpenAI

```bash
export OPENAI_API_KEY="<OPENAI_KEY>"
export BASE_URL="https://api.openai.com/v1"
export MODEL="gpt-4o-mini"
./mini-agent.sh
```

### 2) OpenRouter

OpenRouter is OpenAI-compatible.

```bash
export OPENAI_API_KEY="<OPENROUTER_API_KEY>"
export BASE_URL="https://openrouter.ai/api/v1"
export MODEL="openai/gpt-4o-mini"
./mini-agent.sh
```

Notes:

- `OPENAI_API_KEY` variable name is still used by this script, even for OpenRouter.
- Model names must be OpenRouter model IDs.

### 3) Ollama

Ollama exposes an OpenAI-compatible endpoint when enabled in your setup.

```bash
# Example local endpoint (adjust for your Ollama configuration)
export OPENAI_API_KEY="ollama"
export BASE_URL="http://localhost:11434/v1"
export MODEL="llama3.1"
./mini-agent.sh
```

Notes:

- The key may be ignored locally by Ollama, but this script always sends `Authorization: Bearer ...`.
- Ensure your Ollama server/version is running with OpenAI-compatible `/v1/chat/completions` support.

### 4) LM Studio

LM Studio provides a local OpenAI-compatible server.

1. Start local server in LM Studio.
2. Set endpoint and model:

```bash
export OPENAI_API_KEY="lm-studio"
export BASE_URL="http://localhost:1234/v1"
export MODEL="<loaded-model-id>"
./mini-agent.sh
```

Notes:

- Replace `<loaded-model-id>` with the exact model ID shown in LM Studio.
- Keep LM Studio server running while using the script.

## Behavior and Safety

- `exec` tool runs shell commands with `timeout 30s`.
- Output is truncated at ~12000 chars.
- Some dangerous command patterns are blocked (`rm -rf`, `mkfs`, `dd if=`, `shutdown`, `reboot`, `poweroff`).

## Troubleshooting

- `Error: OPENAI_API_KEY is required.`
  - Set `OPENAI_API_KEY` before running.
- `API error: ...`
  - Check `BASE_URL`, `MODEL`, and provider key.
- `curl` / `jq` missing
  - Install dependencies first.
