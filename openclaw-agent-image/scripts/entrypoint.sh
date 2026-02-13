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
  log "Shutdown signal received (${1:-unknown})"

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

trap 'shutdown SIGTERM' SIGTERM
trap 'shutdown SIGINT'  SIGINT
trap 'shutdown SIGHUP'  SIGHUP

main() {
  # Defaults (keep env var names aligned with OpenClaw docs)
  export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/home/openclaw/.openclaw}"
  export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/run/openclaw/openclaw.json}"
  export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  export OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

  # Only these are required for the container to boot; rest are optional (less functional if missing).
  require_env "AGENT_ID"
  require_env "OPENCLAW_GATEWAY_TOKEN"

  # Read baked build metadata (set early so boot log can use them)
  local baked_ver="" commit_sha=""
  baked_ver="$(cat /etc/openclaw/VERSION 2>/dev/null || true)"
  commit_sha="$(cat /etc/openclaw/GIT_COMMIT_SHA 2>/dev/null || true)"

  # Never leak AWS_* creds into the gateway process.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE || true

  log "Booting agent: ${AGENT_ID} (v${baked_ver} @ ${commit_sha:0:7})"

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

  # 4) Run migrations/repair — only when the OpenClaw version has changed.
  #    /etc/openclaw/VERSION is baked into the image at build time.
  #    workspace/.openclaw-version is persisted via S3 backup/restore.
  local restored_ver=""
  restored_ver="$(cat "${OPENCLAW_STATE_DIR}/workspace/.openclaw-version" 2>/dev/null || true)"

  if [[ "${baked_ver}" != "${restored_ver}" ]]; then
    log "Version change detected (${restored_ver:-none} -> ${baked_ver}), running doctor"
    if openclaw doctor --repair --non-interactive; then
      log "Doctor completed"
    else
      warn "Doctor reported warnings (continuing)"
    fi

    # Stamp the version so subsequent same-version boots skip doctor.
    echo "${baked_ver}" > "${OPENCLAW_STATE_DIR}/workspace/.openclaw-version"
    log "Version marker written: ${baked_ver}"
  else
    log "Same version (${baked_ver}), skipping doctor"
  fi

  # 4b) Re-assert channel plugin enabled state. The config is re-rendered fresh
  #     from the template on every boot, so plugins.entries.*.enabled is never
  #     set by setup-channels. Doctor sets it when it runs, but on same-version
  #     boots we skip doctor. Assert it unconditionally.
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    local tmp; tmp="$(mktemp)"
    if jq '.plugins.entries.telegram.enabled = true' "${OPENCLAW_CONFIG_PATH}" > "${tmp}"; then
      mv "${tmp}" "${OPENCLAW_CONFIG_PATH}"
      log "Telegram plugin enabled"
    else
      rm -f "${tmp}"
      warn "Failed to enable Telegram plugin (continuing)"
    fi
  fi

  if [[ -n "${WHATSAPP_ALLOWFROM:-}" ]]; then
    local wa_cred_dir="${OPENCLAW_STATE_DIR}/credentials/whatsapp"
    if [[ -d "${wa_cred_dir}" ]] && [[ -n "$(ls -A "${wa_cred_dir}" 2>/dev/null)" ]]; then
      local tmp; tmp="$(mktemp)"
      if jq '.plugins.entries.whatsapp.enabled = true' "${OPENCLAW_CONFIG_PATH}" > "${tmp}"; then
        mv "${tmp}" "${OPENCLAW_CONFIG_PATH}"
        log "WhatsApp plugin enabled (credentials found)"
      else
        rm -f "${tmp}"
        warn "Failed to enable WhatsApp plugin (continuing)"
      fi
    else
      warn "WhatsApp credentials not found — plugin NOT enabled (gateway would crash without them)"
      warn "To complete first-time setup: doctl apps console <app-id> openclaw-agent → openclaw channels login"
      warn "After QR scan, credentials sync to S3 within 60s. Redeploy to activate WhatsApp."
    fi
  fi

  # 4c) Install skills from ClawHub (OPENCLAW_SKILLS env, comma-separated slugs)
  local skills_csv="${OPENCLAW_SKILLS:-}"
  skills_csv="$(echo "${skills_csv}" | tr -d '[:space:]')"
  if [[ -n "${skills_csv}" ]]; then
    IFS=',' read -ra skill_slugs <<< "${skills_csv}"
    for slug in "${skill_slugs[@]}"; do
      if [[ -d "${OPENCLAW_STATE_DIR}/workspace/skills/${slug}" ]]; then
        log "Skill already present: ${slug} (skipping install)"
        continue
      fi
      if npx --yes clawhub@latest install "${slug}" 2>&1; then
        log "Skill installed: ${slug}"
      else
        warn "Failed to install skill: ${slug} (continuing)"
      fi
    done
    log "Skills install complete (${#skill_slugs[@]} requested)"
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

  log "Gateway launched (PID ${GATEWAY_PID})"
  wait "${GATEWAY_PID}"
}

main "$@"

