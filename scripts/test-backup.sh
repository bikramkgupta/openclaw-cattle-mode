#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-backup.sh — Automated backup/restore test for OpenClaw Cattle Mode
#
# Validates:
#   1. Customer-seeded workspace files are restored and never overwritten
#   2. Runtime state (memory, MEMORY.md, credentials) is backed up and restored
#   3. Final backup on shutdown captures last-minute changes
#
# Requirements:
#   - Docker + Docker Compose
#   - .env.docker populated with required values (TELEGRAM_BOT_TOKEN, GRADIENT_API_KEY, etc.)
#   - aws CLI installed on the host (for S3 verification against localhost:9000)
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log()  { echo -e "${GREEN}[test]${NC} $1"; }
warn() { echo -e "${YELLOW}[test]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; (( FAIL++ )) || true; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; (( PASS++ )) || true; }

rustfs_endpoint() {
  # Prefer localhost (Docker Desktop / native), fall back to container IP (OrbStack)
  if curl -s -o /dev/null -w '' http://localhost:9000/ 2>/dev/null; then
    echo "http://localhost:9000"
  else
    local ip
    ip=$(docker inspect openclaw-cattle-mode-rustfs-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    echo "http://${ip}:9000"
  fi
}

aws_local() {
  AWS_ACCESS_KEY_ID=rustfsadmin \
  AWS_SECRET_ACCESS_KEY=rustfsadmin \
  AWS_DEFAULT_REGION=us-east-1 \
  AWS_EC2_METADATA_DISABLED=true \
  aws --endpoint-url "${RUSTFS_URL}" "$@"
}

wait_for_health() {
  local max_wait="${1:-90}"
  log "Waiting for agent health (up to ${max_wait}s)..."
  for i in $(seq 1 "$max_wait"); do
    if dc exec -T openclaw-agent /usr/local/bin/openclaw-healthcheck >/dev/null 2>&1; then
      log "Agent healthy after ${i}s"
      return 0
    fi
    sleep 1
  done
  fail "Agent did not become healthy within ${max_wait}s"
  return 1
}

dump_agent_logs() {
  echo ""
  log "=== Container logs (openclaw-agent) ==="
  docker logs openclaw-cattle-mode-openclaw-agent-1 2>&1 | tail -80 || true
  echo ""
}

cleanup() {
  log "Cleaning up..."
  cd "$PROJECT_DIR"
  docker compose --env-file "${PROJECT_DIR}/.env.docker" down -v 2>/dev/null || true
}

# ---- Pre-flight checks ----

ENV_FILE="${PROJECT_DIR}/.env.docker"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.docker.example to .env.docker and fill in required values."
  exit 1
fi

# Warn on duplicate keys in env file (indicates secret contamination)
_dupes=$(awk -F= 'NF>1 && $1!="" {print $1}' "${ENV_FILE}" | sort | uniq -d)
if [[ -n "$_dupes" ]]; then
  warn "Duplicate keys in ${ENV_FILE}: ${_dupes} (last-match-wins applies)"
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found. Install it: pip install awscli"
  exit 1
fi

# All docker compose calls use the .env.docker file
dc() { docker compose --env-file "${ENV_FILE}" "$@"; }

trap cleanup EXIT

cd "$PROJECT_DIR"

# ---- Step 1: Clean slate ----
log "Step 1: Clean slate"
dc down -v 2>/dev/null || true

# Read config from the same env file docker compose uses, so S3 paths match.
_env_val() { grep "^${1}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }

BUCKET="$(_env_val SPACES_BUCKET)"
BUCKET="${BUCKET:-openclaw-dev}"
AGENT_ID="$(_env_val AGENT_ID)"
AGENT_ID="${AGENT_ID:-agent-dev}"
S3_PREFIX="s3://${BUCKET}/openclaw/${AGENT_ID}"

log "S3 prefix: ${S3_PREFIX}"

# ---- Step 2: Start RustFS and seed customer workspace files ----
log "Step 2: Starting RustFS"
dc up -d --build rustfs rustfs-bucket
sleep 5

RUSTFS_URL="$(rustfs_endpoint)"
log "Using RustFS endpoint: ${RUSTFS_URL}"

log "Step 3: Seeding customer workspace files in RustFS"
echo "# Test Soul File" | aws_local s3 cp - "${S3_PREFIX}/workspace/SOUL.md"
echo "# Test Agents File" | aws_local s3 cp - "${S3_PREFIX}/workspace/AGENTS.md"

if aws_local s3 ls "${S3_PREFIX}/workspace/SOUL.md" >/dev/null 2>&1; then
  pass "Customer workspace files seeded in RustFS"
else
  fail "Could not seed customer workspace files"
fi

# ---- Step 4: Start agent (restore pulls customer files from S3) ----
log "Step 4: Starting agent"
dc up -d openclaw-agent

# ---- Step 5: Wait for agent health ----
log "Step 5: Waiting for agent health"
wait_for_health 90 || exit 1

# ---- Step 6: Write runtime state files inside the container ----
log "Step 6: Writing runtime state files in container"

dc exec -T openclaw-agent bash -c '
  mkdir -p /home/openclaw/.openclaw/workspace/memory /home/openclaw/.openclaw/credentials
  echo "# Memory for 2026-02-08" > /home/openclaw/.openclaw/workspace/memory/2026-02-08.md
  echo "# Curated Memory" > /home/openclaw/.openclaw/workspace/MEMORY.md
  echo "{\"test\": true}" > /home/openclaw/.openclaw/credentials/test-oauth.json
'
pass "Runtime state files written"

# ---- Step 7: Wait for backup to trigger ----
log "Step 7: Waiting for periodic backup (60s interval + margin)..."
sleep 65

# ---- Step 8: Verify backup in RustFS ----
log "Step 8: Verifying backup in RustFS"

if aws_local s3 ls "${S3_PREFIX}/workspace/memory/2026-02-08.md" >/dev/null 2>&1; then
  pass "Memory file backed up to RustFS"
else
  fail "Memory file NOT found in RustFS"
fi

if aws_local s3 ls "${S3_PREFIX}/workspace/MEMORY.md" >/dev/null 2>&1; then
  pass "MEMORY.md backed up to RustFS"
else
  fail "MEMORY.md NOT found in RustFS"
fi

if aws_local s3 ls "${S3_PREFIX}/credentials/test-oauth.json" >/dev/null 2>&1; then
  pass "Credentials backed up to RustFS"
else
  fail "Credentials NOT found in RustFS"
fi

# ---- Step 9: Verify customer files NOT overwritten ----
log "Step 9: Verifying customer workspace files are intact"

SOUL_CONTENT=$(aws_local s3 cp "${S3_PREFIX}/workspace/SOUL.md" - 2>/dev/null || true)
if [[ "${SOUL_CONTENT}" == "# Test Soul File" ]]; then
  pass "Customer SOUL.md not overwritten by backup"
else
  fail "Customer SOUL.md was overwritten! Content: ${SOUL_CONTENT}"
fi

# ---- Step 10: Restart agent only ----
log "Step 10: Restarting agent (stop + rm + up)"
dc stop openclaw-agent
dc rm -f openclaw-agent
dc up -d openclaw-agent

# ---- Step 11: Wait for health after restart ----
log "Step 11: Waiting for agent health after restart"
wait_for_health 90 || exit 1

# ---- Step 12: Verify restore ----
log "Step 12: Verifying restored files"

MEMORY_RESTORED=$(dc exec -T openclaw-agent cat /home/openclaw/.openclaw/workspace/memory/2026-02-08.md 2>/dev/null || true)
if [[ "${MEMORY_RESTORED}" == *"Memory for 2026-02-08"* ]]; then
  pass "Memory file restored after restart"
else
  fail "Memory file NOT restored after restart"
fi

CURATED_RESTORED=$(dc exec -T openclaw-agent cat /home/openclaw/.openclaw/workspace/MEMORY.md 2>/dev/null || true)
if [[ "${CURATED_RESTORED}" == *"Curated Memory"* ]]; then
  pass "MEMORY.md restored after restart"
else
  fail "MEMORY.md NOT restored after restart"
fi

CRED_RESTORED=$(dc exec -T openclaw-agent cat /home/openclaw/.openclaw/credentials/test-oauth.json 2>/dev/null || true)
if [[ "${CRED_RESTORED}" == *"test"* ]]; then
  pass "Credentials restored after restart"
else
  fail "Credentials NOT restored after restart"
fi

SOUL_RESTORED=$(dc exec -T openclaw-agent cat /home/openclaw/.openclaw/workspace/SOUL.md 2>/dev/null || true)
if [[ "${SOUL_RESTORED}" == *"Test Soul File"* ]]; then
  pass "Customer SOUL.md restored after restart"
else
  fail "Customer SOUL.md NOT restored after restart"
fi

# ---- Step 13: Test final backup on shutdown ----
log "Step 13: Testing final backup on shutdown"

dc exec -T openclaw-agent bash -c '
  echo "# Shutdown test file" > /home/openclaw/.openclaw/workspace/memory/shutdown-test.md
'

# Stop the agent (triggers shutdown trap -> final backup)
dc stop openclaw-agent
sleep 3

if aws_local s3 ls "${S3_PREFIX}/workspace/memory/shutdown-test.md" >/dev/null 2>&1; then
  pass "Final backup captured shutdown-test.md"
else
  fail "Final backup did NOT capture shutdown-test.md"
fi

# ---- Summary ----
echo ""
echo "========================================"
echo -e "  ${GREEN}PASSED: ${PASS}${NC}"
echo -e "  ${RED}FAILED: ${FAIL}${NC}"
echo "========================================"

if [[ "${FAIL}" -gt 0 ]]; then
  dump_agent_logs
  exit 1
fi
exit 0
