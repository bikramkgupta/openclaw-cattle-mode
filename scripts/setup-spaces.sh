#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-spaces.sh — Create a DigitalOcean Spaces bucket for OpenClaw
#
# Creates a Spaces bucket and prints the env vars you need to set in
# App Platform. Requires doctl and aws CLI.
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup-spaces]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup-spaces]${NC} $1"; }

# ---- Pre-flight checks ----

if ! command -v doctl >/dev/null 2>&1; then
  echo "ERROR: doctl not found. Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found. Install it: pip install awscli"
  exit 1
fi

if ! doctl account get >/dev/null 2>&1; then
  echo "ERROR: doctl not authenticated. Run: doctl auth init"
  exit 1
fi

# ---- Configuration ----

read -rp "Spaces region [syd1]: " REGION
REGION="${REGION:-syd1}"

DEFAULT_BUCKET="openclaw-cattle-mode-${REGION}"
read -rp "Bucket name [${DEFAULT_BUCKET}]: " BUCKET
BUCKET="${BUCKET:-${DEFAULT_BUCKET}}"

ENDPOINT="https://${REGION}.digitaloceanspaces.com"

# ---- Create bucket ----

log "Creating Spaces bucket: ${BUCKET} in ${REGION}"

# Check if user has Spaces access keys configured for aws CLI
if [[ -z "${SPACES_ACCESS_KEY_ID:-}" ]] || [[ -z "${SPACES_SECRET_ACCESS_KEY:-}" ]]; then
  warn "SPACES_ACCESS_KEY_ID and SPACES_SECRET_ACCESS_KEY not set."
  echo ""
  echo "To create a Spaces access key:"
  echo "  1. Go to https://cloud.digitalocean.com/account/api/spaces"
  echo "  2. Click 'Generate New Key'"
  echo "  3. Export the keys and re-run this script:"
  echo ""
  echo "     export SPACES_ACCESS_KEY_ID=<your-key>"
  echo "     export SPACES_SECRET_ACCESS_KEY=<your-secret>"
  echo "     bash scripts/setup-spaces.sh"
  echo ""
  exit 1
fi

AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID}" \
AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY}" \
AWS_EC2_METADATA_DISABLED=true \
aws s3 mb "s3://${BUCKET}" --endpoint-url "${ENDPOINT}" --region "${REGION}" 2>&1 || {
  warn "Bucket may already exist (that's fine)"
}

log "Bucket ready: ${BUCKET}"

# ---- Print env vars ----

echo ""
echo "========================================"
echo "  Set these in App Platform"
echo "========================================"
echo ""
echo "SPACES_BUCKET=${BUCKET}"
echo "SPACES_REGION=${REGION}"
echo "SPACES_ACCESS_KEY_ID=${SPACES_ACCESS_KEY_ID}"
echo "SPACES_SECRET_ACCESS_KEY=${SPACES_SECRET_ACCESS_KEY}"
echo ""
echo "Set these as environment variables in your App Platform app."
echo "Mark SPACES_ACCESS_KEY_ID and SPACES_SECRET_ACCESS_KEY as secrets."
echo "========================================"
