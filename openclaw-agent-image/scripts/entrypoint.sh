#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[openclaw-agent]${NC} $1"; }
warn() { echo -e "${YELLOW}[openclaw-agent]${NC} $1"; }
error() { echo -e "${RED}[openclaw-agent]${NC} $1" >&2; }

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    error "Missing required env var: ${name}"
    exit 1
  fi
}

shutdown() {
  log "Shutdown signal received"

  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
  fi

  if [[ -n "${BACKUP_PID:-}" ]] && kill -0 "${BACKUP_PID}" 2>/dev/null; then
    kill "${BACKUP_PID}" 2>/dev/null || true
  fi

  log "Final backup..."
  /usr/local/bin/openclaw-backup --final || warn "Final backup failed (continuing shutdown)"

  if [[ -n "${GATEWAY_PID:-}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill -TERM "${GATEWAY_PID}" 2>/dev/null || true
    wait "${GATEWAY_PID}" 2>/dev/null || true
  fi

  log "Shutdown complete"
  exit 0
}

trap shutdown SIGTERM SIGINT SIGHUP

main() {
  # Defaults (keep env var names aligned with OpenClaw docs)
  export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/home/openclaw/.openclaw}"
  export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/run/openclaw/openclaw.json}"
  export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  export OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

  # Only these are required for the container to boot; rest are optional (less functional if missing).
  require_env "AGENT_ID"
  require_env "OPENCLAW_GATEWAY_TOKEN"

  # Never leak AWS_* creds into the gateway process.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE || true

  log "Booting agent: ${AGENT_ID}"

  mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory" "${OPENCLAW_STATE_DIR}/credentials" "${OPENCLAW_STATE_DIR}/agents"
  mkdir -p "$(dirname "${OPENCLAW_CONFIG_PATH}")"

  # 1) Render base config (template -> OPENCLAW_CONFIG_PATH)
  envsubst < /etc/openclaw/openclaw.base.json > "${OPENCLAW_CONFIG_PATH}"
  chmod 600 "${OPENCLAW_CONFIG_PATH}" || true

  # 2) Apply providers + channel config (writes OPENCLAW_CONFIG_PATH)
  /usr/local/bin/openclaw-setup-providers
  /usr/local/bin/openclaw-setup-channels

  # 3) Restore workspace + runtime state from object store
  /usr/local/bin/openclaw-restore || warn "Restore failed (starting fresh)"

  # 4) Run migrations/repair (safe, idempotent)
  if openclaw doctor --repair --non-interactive; then
    log "Doctor completed"
  else
    warn "Doctor reported warnings (continuing)"
  fi

  # 4b) Re-assert channel plugin state after doctor (2026.2.9+ doctor may
  #     set plugins.entries.telegram.enabled=false even when channels.telegram
  #     is fully configured). Re-apply what setup-channels intended.
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    local tmp; tmp="$(mktemp)"
    if jq '.plugins.entries.telegram.enabled = true' "${OPENCLAW_CONFIG_PATH}" > "${tmp}"; then
      mv "${tmp}" "${OPENCLAW_CONFIG_PATH}"
      log "Telegram plugin re-enabled after doctor"
    else
      rm -f "${tmp}"
      warn "Failed to re-enable Telegram plugin (continuing)"
    fi
  fi

  # 4b-ii) Re-assert WhatsApp plugin state after doctor (same issue as Telegram).
  if [[ -n "${WHATSAPP_ALLOWFROM:-}" ]]; then
    local tmp; tmp="$(mktemp)"
    if jq '.plugins.entries.whatsapp.enabled = true' "${OPENCLAW_CONFIG_PATH}" > "${tmp}"; then
      mv "${tmp}" "${OPENCLAW_CONFIG_PATH}"
      log "WhatsApp plugin re-enabled after doctor"
    else
      rm -f "${tmp}"
      warn "Failed to re-enable WhatsApp plugin (continuing)"
    fi
  fi

  # 4c) Enable bundled skills (from OPENCLAW_SKILLS env, comma-separated)
  local skills_csv="${OPENCLAW_SKILLS:-}"
  skills_csv="$(echo "${skills_csv}" | tr -d '[:space:]')"
  if [[ -n "${skills_csv}" ]]; then
    local skills_json
    skills_json="$(echo "${skills_csv}" | tr ',' '\n' | jq -R . | jq -s .)"

    # Build entries object: {"weather": {"enabled": true}, "calendar": {"enabled": true}, ...}
    local entries_json
    entries_json="$(echo "${skills_csv}" | tr ',' '\n' | jq -R '{(.): {"enabled": true}}' | jq -s 'add')"

    local tmp; tmp="$(mktemp)"
    if jq --argjson allow "${skills_json}" --argjson entries "${entries_json}" '
      .skills //= {} |
      .skills.allowBundled = $allow |
      .skills.entries = (.skills.entries // {} | . * $entries)
    ' "${OPENCLAW_CONFIG_PATH}" > "${tmp}"; then
      mv "${tmp}" "${OPENCLAW_CONFIG_PATH}"
      log "Skills configured: ${skills_csv}"
    else
      rm -f "${tmp}"
      warn "Failed to configure skills (continuing)"
    fi
  fi

  # 5) Start gateway
  log "Starting gateway on port ${OPENCLAW_GATEWAY_PORT} (bind=${OPENCLAW_GATEWAY_BIND})"
  openclaw gateway \
    --allow-unconfigured \
    --port "${OPENCLAW_GATEWAY_PORT}" \
    --bind "${OPENCLAW_GATEWAY_BIND}" \
    --token "${OPENCLAW_GATEWAY_TOKEN}" &
  GATEWAY_PID=$!

  # 6) Start backup watcher (selective, debounced)
  /usr/local/bin/openclaw-backup &
  BACKUP_PID=$!

  # 7) Daily restart watchdog — recycle the container every 24h to prevent
  #    slow memory leaks from long-running sessions.
  (
    sleep 86400  # 24 hours
    log "Daily restart: recycling gateway (uptime 24h)"
    kill -TERM "${GATEWAY_PID}" 2>/dev/null || true
  ) &
  WATCHDOG_PID=$!

  log "Ready"
  wait "${GATEWAY_PID}"
}

main "$@"

