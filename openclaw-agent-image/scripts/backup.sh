#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[backup]${NC} $1"; }
warn() { echo -e "${YELLOW}[backup]${NC} $1"; }
error() { echo -e "${RED}[backup]${NC} $1" >&2; }

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/home/openclaw/.openclaw}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"

# Written by restore.sh on successful restore; tells us --delete is safe.
RESTORE_MARKER="${OPENCLAW_STATE_DIR}/.restore-complete"

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    error "Missing required env var: ${name}"
    exit 1
  fi
}

endpoint_url_arg() {
  if [[ -n "${S3_ENDPOINT_URL}" ]]; then
    printf '%s\0%s\0' "--endpoint-url" "${S3_ENDPOINT_URL}"
  else
    printf '%s\0%s\0' "--endpoint-url" "https://${SPACES_REGION}.digitaloceanspaces.com"
  fi
}

sync_item() {
  local local_rel="$1"
  local remote_rel="$2"

  local local_path="${OPENCLAW_STATE_DIR}/${local_rel}"
  local remote_path="${S3_PATH}/${remote_rel}"

  local -a args=()
  mapfile -d '' -t args < <(endpoint_url_arg)

  if [[ -d "${local_path}" ]]; then
    # Only --delete when restore completed fully; otherwise additive-only
    # to avoid wiping S3 state that wasn't restored.
    if [[ -f "${RESTORE_MARKER}" ]]; then
      aws s3 sync "${local_path}" "${remote_path}/" "${args[@]}" --delete --quiet 2>/dev/null || \
        warn "Failed to sync dir: ${local_rel}"
    else
      aws s3 sync "${local_path}" "${remote_path}/" "${args[@]}" --quiet 2>/dev/null || \
        warn "Failed to sync dir: ${local_rel}"
    fi
  elif [[ -f "${local_path}" ]]; then
    aws s3 cp "${local_path}" "${remote_path}" "${args[@]}" --quiet 2>/dev/null || \
      warn "Failed to sync file: ${local_rel}"
  fi
}

backup_all() {
  # S3 is the brain — back up all runtime state.
  # workspace/  : AGENTS.md, SOUL.md, memory/, MEMORY.md, etc.
  # agents/     : sessions, auth profiles, model registry (all agentIds)
  # credentials/: OAuth tokens, API keys
  sync_item "workspace" "workspace"
  sync_item "agents" "agents"
  sync_item "credentials" "credentials"
}

final_backup() {
  log "Final backup requested"
  backup_all
  log "Final backup complete"
}

watch_inotify() {
  log "Watching for changes with inotify"

  local last_sync=0
  while true; do
    inotifywait -r -q -e create,modify,delete,move \
      "${OPENCLAW_STATE_DIR}/workspace" \
      "${OPENCLAW_STATE_DIR}/credentials" \
      "${OPENCLAW_STATE_DIR}/agents" \
      2>/dev/null || true

    local now
    now="$(date +%s)"
    if (( now - last_sync >= DEBOUNCE_SECONDS )); then
      sleep "${DEBOUNCE_SECONDS}"
      backup_all
      last_sync="$(date +%s)"
    fi
  done
}

watch_polling() {
  log "Watching for changes with polling every ${POLL_INTERVAL_SECONDS}s"
  local last=""

  while true; do
    sleep "${POLL_INTERVAL_SECONDS}"

    local cur=""
    for dir in workspace agents credentials; do
      if [[ -d "${OPENCLAW_STATE_DIR}/${dir}" ]]; then
        cur+=$(find "${OPENCLAW_STATE_DIR}/${dir}" -type f -exec stat -c '%Y%s' {} \; 2>/dev/null || true)
      fi
    done

    cur="$(echo -n "${cur}" | md5sum | cut -d' ' -f1)"
    if [[ "${cur}" != "${last}" ]]; then
      log "Changes detected; syncing"
      backup_all
      last="${cur}"
    fi
  done
}

main() {
  if [[ "${1:-}" == "--final" ]]; then
    require_env "AGENT_ID"
    require_env "SPACES_BUCKET"
    require_env "SPACES_REGION"
    require_env "SPACES_ACCESS_KEY_ID"
    require_env "SPACES_SECRET_ACCESS_KEY"
    export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}"
    export AWS_DEFAULT_REGION="${SPACES_REGION}"
    export AWS_EC2_METADATA_DISABLED="true"
    S3_PATH="s3://${SPACES_BUCKET}/openclaw/${AGENT_ID}"
    final_backup
    return 0
  fi

  require_env "AGENT_ID"
  require_env "SPACES_BUCKET"
  require_env "SPACES_REGION"
  require_env "SPACES_ACCESS_KEY_ID"
  require_env "SPACES_SECRET_ACCESS_KEY"

  # Export AWS_* ONLY in this process (do not leak into gateway)
  export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION="${SPACES_REGION}"
  export AWS_EC2_METADATA_DISABLED="true"

  S3_PATH="s3://${SPACES_BUCKET}/openclaw/${AGENT_ID}"

  mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory" "${OPENCLAW_STATE_DIR}/credentials" "${OPENCLAW_STATE_DIR}/agents"

  log "Backing up runtime state to: ${S3_PATH}"
  backup_all

  if command -v inotifywait >/dev/null 2>&1; then
    watch_inotify
  else
    warn "inotifywait not available; using polling"
    watch_polling
  fi
}

main "$@"
