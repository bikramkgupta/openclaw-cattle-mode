#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[channels]${NC} $1"; }
warn() { echo -e "${YELLOW}[channels]${NC} $1"; }

CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-/run/openclaw/openclaw.json}"

ensure_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi
}

add_telegram() {
  local token="${TELEGRAM_BOT_TOKEN:-}"
  if [[ -z "${token}" ]]; then
    warn "TELEGRAM_BOT_TOKEN not set; skipping Telegram channel"
    return 0
  fi

  local allowlist="${TELEGRAM_ALLOWFROM:-}"
  allowlist="$(echo "${allowlist}" | tr -d '[:space:]')"
  local tmp
  tmp="$(mktemp)"

if [[ -n "${allowlist}" ]]; then
  log "Configuring Telegram: allowlist mode"
  # Convert comma-separated list to JSON array of strings.
  local allow_json
  allow_json="$(echo "${allowlist}" | tr ',' '\n' | jq -R . | jq -s .)"

  jq --arg token "${token}" --argjson allow "${allow_json}" '
    .channels //= {} |
    .channels.telegram = {
      "enabled": true,
      "botToken": $token,
      "dmPolicy": "allowlist",
      "allowFrom": $allow
    }
  ' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
else
  log "Configuring Telegram: pairing mode"
  jq --arg token "${token}" '
    .channels //= {} |
    .channels.telegram = {
      "enabled": true,
      "botToken": $token,
      "dmPolicy": "pairing"
    }
  ' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
fi
}

main() {
  ensure_file
  add_telegram
  warn "V0 scaffold: only Telegram is configured (other channels intentionally omitted)"
  log "Channel setup complete"
}

main "$@"
