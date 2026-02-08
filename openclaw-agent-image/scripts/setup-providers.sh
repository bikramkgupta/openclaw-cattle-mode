#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[providers]${NC} $1"; }
warn() { echo -e "${YELLOW}[providers]${NC} $1"; }

CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-/run/openclaw/openclaw.json}"

ensure_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi
}

add_gradient_provider() {
  if [[ -z "${GRADIENT_API_KEY:-}" ]]; then
    echo "GRADIENT_API_KEY is required for V0" >&2
    exit 1
  fi

log "Configuring Gradient (DigitalOcean) provider"

local tmp
tmp="$(mktemp)"

jq --arg key "${GRADIENT_API_KEY}" '
  .models.mode = "merge" |
  .models.providers.gradient = {
    "baseUrl": "https://inference.do-ai.run/v1",
    "apiKey": $key,
    "api": "openai-completions",
    "models": [
      {
        "id": "anthropic-claude-opus-4.6",
        "name": "Anthropic Claude Opus 4.6",
        "reasoning": false,
        "compat": { "maxTokensField": "max_tokens", "supportsStore": false },
        "input": ["text"],
        "contextWindow": 200000,
        "maxTokens": 8192
      }
    ]
  }
' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"

tmp="$(mktemp)"
jq '
  .agents.defaults.models //= {} |
  .agents.defaults.models["gradient/anthropic-claude-opus-4.6"] = { "params": { "maxTokens": 8192 } }
' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
}

add_anthropic_provider() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi
  log "Configuring Anthropic provider"

  local tmp
  tmp="$(mktemp)"
  jq --arg key "${ANTHROPIC_API_KEY}" '
    .models.mode = "merge" |
    .models.providers.anthropic = { "apiKey": $key }
  ' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
}

add_openai_provider() {
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi
  log "Configuring OpenAI provider"

  local tmp
  tmp="$(mktemp)"
  jq --arg key "${OPENAI_API_KEY}" '
    .models.mode = "merge" |
    .models.providers.openai = { "apiKey": $key }
  ' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
}

set_default_model() {
  local model=""

  if [[ -n "${AGENT_DEFAULT_MODEL:-}" ]]; then
    model="${AGENT_DEFAULT_MODEL}"
    log "Using AGENT_DEFAULT_MODEL override: ${model}"
  elif [[ -n "${GRADIENT_API_KEY:-}" ]]; then
    model="gradient/anthropic-claude-opus-4.6"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    model="anthropic/claude-opus-4-6"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    model="openai/gpt-5.1-codex"
  else
    warn "No provider auth found; agent will have no default model"
    return 0
  fi

local tmp
tmp="$(mktemp)"
jq --arg model "${model}" '
  .agents.defaults.model.primary = $model
' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
}

main() {
  ensure_file
  add_gradient_provider
  add_anthropic_provider
  add_openai_provider
  set_default_model
  log "Provider setup complete"
}

main "$@"
