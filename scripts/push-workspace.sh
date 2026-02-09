#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# push-workspace.sh — Upload workspace files to Spaces (the agent's brain)
#
# Spaces is the single source of truth for all agent state. Use this script
# to update workspace files (AGENTS.md, SOUL.md, etc.) between deploys.
# Changes take effect on the next container restart/redeploy.
#
# Usage:
#   bash scripts/push-workspace.sh AGENTS.md          # upload a single file
#   bash scripts/push-workspace.sh workspace/          # upload a directory
#   bash scripts/push-workspace.sh --list              # list current workspace in S3
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env.remote"

log()  { echo -e "${GREEN}[push]${NC} $1"; }
fail() { echo -e "${RED}[push]${NC} $1"; exit 1; }

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE}. Copy .env.remote.example to .env.remote and fill in values."
fi

# Load .env.remote
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  value="${value%\"}"
  value="${value#\"}"
  export "$key=$value"
done < "${ENV_FILE}"

export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${SPACES_REGION}"
export AWS_EC2_METADATA_DISABLED="true"

S3_PATH="s3://${SPACES_BUCKET}/openclaw/${AGENT_ID}"
ENDPOINT="https://${SPACES_REGION}.digitaloceanspaces.com"

if [[ "${1:-}" == "--list" ]]; then
  log "Listing: ${S3_PATH}/workspace/"
  aws s3 ls "${S3_PATH}/workspace/" --recursive --endpoint-url "${ENDPOINT}" 2>&1
  exit 0
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage:"
  echo "  bash scripts/push-workspace.sh <file-or-dir>   Upload to workspace in S3"
  echo "  bash scripts/push-workspace.sh --list           List current workspace in S3"
  echo ""
  echo "Examples:"
  echo "  bash scripts/push-workspace.sh AGENTS.md        Upload AGENTS.md"
  echo "  bash scripts/push-workspace.sh workspace/       Upload entire workspace/ dir"
  echo ""
  echo "S3 path: ${S3_PATH}/workspace/"
  exit 1
fi

SOURCE="$1"

if [[ -d "${SOURCE}" ]]; then
  # Directory: sync to workspace/
  log "Syncing directory: ${SOURCE} → ${S3_PATH}/workspace/"
  aws s3 sync "${SOURCE}" "${S3_PATH}/workspace/" --endpoint-url "${ENDPOINT}" 2>&1
  log "Done. Changes take effect on next redeploy."
elif [[ -f "${SOURCE}" ]]; then
  # Single file: upload to workspace/<filename>
  FILENAME="$(basename "${SOURCE}")"
  log "Uploading: ${SOURCE} → ${S3_PATH}/workspace/${FILENAME}"
  aws s3 cp "${SOURCE}" "${S3_PATH}/workspace/${FILENAME}" --endpoint-url "${ENDPOINT}" 2>&1
  log "Done. Changes take effect on next redeploy."
else
  fail "Not found: ${SOURCE}"
fi
