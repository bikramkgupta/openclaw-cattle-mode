#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[restore]${NC} $1"; }
warn() { echo -e "${YELLOW}[restore]${NC} $1"; }
error() { echo -e "${RED}[restore]${NC} $1" >&2; }

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/home/openclaw/.openclaw}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"

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

check_bucket_access() {
  local -a args=()
  mapfile -d '' -t args < <(endpoint_url_arg)
  aws s3 ls "s3://${SPACES_BUCKET}/" "${args[@]}" &>/dev/null
}

remote_exists() {
  local remote_rel="$1"
  local -a args=()
  mapfile -d '' -t args < <(endpoint_url_arg)
  aws s3 ls "${S3_PATH}/${remote_rel}" "${args[@]}" &>/dev/null
}

restore_file() {
  local remote_rel="$1"
  local local_path="${OPENCLAW_STATE_DIR}/${remote_rel}"

  if ! remote_exists "${remote_rel}"; then
    return 1
  fi

  mkdir -p "$(dirname "${local_path}")"
  local -a args=()
  mapfile -d '' -t args < <(endpoint_url_arg)
  aws s3 cp "${S3_PATH}/${remote_rel}" "${local_path}" "${args[@]}" --quiet 2>/dev/null
}

restore_dir() {
  local remote_rel="$1"
  local local_path="${OPENCLAW_STATE_DIR}/${remote_rel}"

  if ! remote_exists "${remote_rel}"; then
    return 1
  fi

  mkdir -p "${local_path}"
  local -a args=()
  mapfile -d '' -t args < <(endpoint_url_arg)
  aws s3 sync "${S3_PATH}/${remote_rel}/" "${local_path}" "${args[@]}" --quiet 2>/dev/null
}

main() {
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

  log "Restoring from: ${S3_PATH}"

  mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory" "${OPENCLAW_STATE_DIR}/credentials"

  if ! check_bucket_access; then
    warn "Cannot access bucket (starting fresh)"
    return 0
  fi

  # Customer-seeded workspace config files (restored if present; never overwritten by backup)
  local cfg_count=0
  for f in \
    "workspace/AGENTS.md" \
    "workspace/SOUL.md" \
    "workspace/USER.md" \
    "workspace/TOOLS.md" \
    "workspace/IDENTITY.md" \
    "workspace/HEARTBEAT.md"
  do
    if restore_file "${f}"; then
      log "Restored config: ${f}"
      ((cfg_count++))
    fi
  done

  if [[ "${cfg_count}" -eq 0 ]]; then
    log "No workspace config files found (OpenClaw defaults will apply)"
  fi

  # Runtime state (backed up + restored)
  restore_dir "workspace/memory" || true
  restore_file "workspace/MEMORY.md" || true
  restore_dir "credentials" || true

  log "Restore complete"
}

main "$@"
