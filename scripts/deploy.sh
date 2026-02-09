#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy.sh — Deploy OpenClaw to DigitalOcean App Platform
#
# Reads .env.remote, substitutes values into app.yaml → temp spec,
# deploys via doctl, then deletes the temp file.
#
# Usage:
#   bash scripts/deploy.sh           # Update spec + deploy
#   bash scripts/deploy.sh --dry-run # Show rendered spec without deploying
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env.remote"
SPEC_TEMPLATE="${PROJECT_DIR}/app.yaml"
TEMP_SPEC="${PROJECT_DIR}/.app-spec-rendered.yaml"
APP_NAME="openclaw-v0"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

log()  { echo -e "${GREEN}[deploy]${NC} $1"; }
fail() { echo -e "${RED}[deploy]${NC} $1"; exit 1; }

# ---- Pre-flight checks ----

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE}. Copy .env.remote.example to .env.remote and fill in values."
fi

if [[ ! -f "${SPEC_TEMPLATE}" ]]; then
  fail "Missing ${SPEC_TEMPLATE}."
fi

if ! command -v doctl &>/dev/null; then
  fail "doctl not found. Install: https://docs.digitalocean.com/reference/doctl/how-to/install/"
fi

if ! command -v envsubst &>/dev/null; then
  fail "envsubst not found. Install: brew install gettext"
fi

# ---- Load .env.remote and substitute into app.yaml ----

log "Loading env from ${ENV_FILE}"

# Export all variables from .env.remote (skip comments and blank lines)
set -a
while IFS='=' read -r key value; do
  # Skip comments and blank lines
  [[ -z "$key" || "$key" == \#* ]] && continue
  # Remove surrounding quotes from value if present
  value="${value%\"}"
  value="${value#\"}"
  export "$key=$value"
done < "${ENV_FILE}"
set +a

log "Rendering spec from app.yaml"
envsubst < "${SPEC_TEMPLATE}" > "${TEMP_SPEC}"

# Verify no unsubstituted variables remain
if grep -q '${' "${TEMP_SPEC}" 2>/dev/null; then
  fail "Unsubstituted variables found in rendered spec:"
  grep '${' "${TEMP_SPEC}"
  rm -f "${TEMP_SPEC}"
  exit 1
fi

if $DRY_RUN; then
  log "Dry run — rendered spec:"
  echo "---"
  cat "${TEMP_SPEC}"
  echo "---"
  rm -f "${TEMP_SPEC}"
  log "Dry run complete. No changes made."
  exit 0
fi

# ---- Find existing app or create ----

log "Looking for app: ${APP_NAME}"
APP_ID=$(doctl apps list --format ID,Spec.Name --no-header 2>/dev/null | grep "${APP_NAME}" | awk '{print $1}' || true)

if [[ -z "${APP_ID}" ]]; then
  log "App not found. Creating..."
  APP_ID=$(doctl apps create --spec "${TEMP_SPEC}" --format ID --no-header 2>&1)
  log "Created app: ${APP_ID}"
else
  log "Found app: ${APP_ID}"
  log "Updating spec..."
  doctl apps update "${APP_ID}" --spec "${TEMP_SPEC}" 2>&1
fi

# ---- Clean up temp file immediately ----

rm -f "${TEMP_SPEC}"
log "Cleaned up temporary spec"

# ---- Trigger deployment ----

log "Triggering deployment..."
DEPLOY_ID=$(doctl apps create-deployment "${APP_ID}" --format ID --no-header 2>/dev/null | head -1)
log "Deployment created: ${DEPLOY_ID}"

# ---- Wait for deployment ----

log "Waiting for deployment to complete (this may take a few minutes)..."
for i in $(seq 1 120); do
  STATUS=$(doctl apps get-deployment "${APP_ID}" "${DEPLOY_ID}" --format Phase,Progress --no-header 2>/dev/null || echo "UNKNOWN")
  PHASE=$(echo "${STATUS}" | awk '{print $1}')

  case "${PHASE}" in
    ACTIVE)
      log "Deployment successful!"
      exit 0
      ;;
    ERROR)
      fail "Deployment failed. Check logs: doctl apps logs ${APP_ID} --type deploy"
      ;;
    CANCELED|SUPERSEDED)
      fail "Deployment ${PHASE}."
      ;;
  esac

  # Print progress every 15s
  if (( i % 15 == 0 )); then
    log "Status: ${STATUS}"
  fi

  sleep 2
done

fail "Deployment timed out after 4 minutes. Check: doctl apps get-deployment ${APP_ID} ${DEPLOY_ID}"
