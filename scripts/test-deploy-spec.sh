#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-deploy-spec.sh — Deploy spec render test for OpenClaw Cattle Mode
#
# Ensures app.yaml has no unsubstituted ${VAR} after envsubst. Uses dummy env
# values so no real secrets are needed. No Docker, no doctl — safe to run in CI.
#
# Requirements: envsubst (e.g. brew install gettext)
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_TEMPLATE="${PROJECT_DIR}/app.yaml"
TEMP_SPEC="${PROJECT_DIR}/.app-spec-rendered-test.yaml"

log()  { echo -e "${GREEN}[test-deploy-spec]${NC} $1"; }
fail() { echo -e "${RED}[test-deploy-spec]${NC} $1"; exit 1; }

# ---- Pre-flight ----

if ! command -v envsubst &>/dev/null; then
  echo "ERROR: envsubst not found. Install: brew install gettext"
  exit 1
fi

if [[ ! -f "${SPEC_TEMPLATE}" ]]; then
  fail "Missing ${SPEC_TEMPLATE}"
fi

# ---- Export every variable that app.yaml uses (dummy values for substitution only) ----
# These are substituted into app.yaml; we only assert no ${VAR} remains.
export IMAGE_TAG="${IMAGE_TAG:-2026.2.6}"
export AGENT_ID="${AGENT_ID:-test-agent}"
export AGENT_NAME="${AGENT_NAME:-Test Agent}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-dummy}"
export TELEGRAM_ALLOWFROM="${TELEGRAM_ALLOWFROM:-0}"
export GRADIENT_API_KEY="${GRADIENT_API_KEY:-dummy}"
export AGENT_DEFAULT_MODEL="${AGENT_DEFAULT_MODEL:-}"
export NODE_OPTIONS="${NODE_OPTIONS:-}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-dummy}"
export SPACES_BUCKET="${SPACES_BUCKET:-test-bucket}"
export SPACES_REGION="${SPACES_REGION:-syd1}"
export SPACES_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID:-dummy}"
export SPACES_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY:-dummy}"

# ---- Render ----
log "Rendering app.yaml with envsubst"
envsubst < "${SPEC_TEMPLATE}" > "${TEMP_SPEC}"

# ---- Assert no unsubstituted variables ----
UNSUB=$(grep '${' "${TEMP_SPEC}" 2>/dev/null || true)
rm -f "${TEMP_SPEC}"
if [[ -n "${UNSUB}" ]]; then
  fail "Unsubstituted variables found in rendered spec:\n${UNSUB}"
fi
log "PASS: All placeholders substituted"
