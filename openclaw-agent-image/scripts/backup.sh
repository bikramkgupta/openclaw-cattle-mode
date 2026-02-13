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

BACKUP_INTERVAL="${BACKUP_INTERVAL:-60}"

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

watch_periodic() {
  log "Watching for changes every ${BACKUP_INTERVAL}s"
  while true; do
    sleep "${BACKUP_INTERVAL}" &
    wait $!          # interruptible by signals
    backup_all
  done
}

main() {
  if [[ -z "${SPACES_BUCKET:-}" || -z "${SPACES_REGION:-}" || -z "${SPACES_ACCESS_KEY_ID:-}" || -z "${SPACES_SECRET_ACCESS_KEY:-}" ]]; then
    warn "Spaces not configured (missing SPACES_*); skipping backup"
    return 0
  fi

  require_env "AGENT_ID"

  if [[ "${1:-}" == "--final" ]]; then
    export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}"
    export AWS_DEFAULT_REGION="${SPACES_REGION}"
    export AWS_EC2_METADATA_DISABLED="true"
    S3_PATH="s3://${SPACES_BUCKET}/openclaw/${AGENT_ID}"
    final_backup
    return 0
  fi

  # Export AWS_* ONLY in this process (do not leak into gateway)
  export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION="${SPACES_REGION}"
  export AWS_EC2_METADATA_DISABLED="true"

  S3_PATH="s3://${SPACES_BUCKET}/openclaw/${AGENT_ID}"

  mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory" "${OPENCLAW_STATE_DIR}/credentials" "${OPENCLAW_STATE_DIR}/agents"

  log "Backing up runtime state to: ${S3_PATH}"
  backup_all

  watch_periodic
}

main "$@"
