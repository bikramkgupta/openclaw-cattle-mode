#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-versions.sh — OpenClaw version compatibility test
#
# Builds and boots the agent container for each specified OpenClaw version,
# verifying that config generation + openclaw doctor works correctly.
#
# Requirements:
#   - Docker + Docker Compose
#   - .env.docker populated with required values
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

VERSIONS="2026.2.1 2026.2.2 2026.2.3 2026.2.6 2026.2.9 2026.2.12"

# Parallel arrays for results (bash 3 compatible)
RESULT_VERSIONS=""
RESULT_STATUSES=""
RESULT_NOTES=""

add_result() {
  RESULT_VERSIONS="${RESULT_VERSIONS}${1}|"
  RESULT_STATUSES="${RESULT_STATUSES}${2}|"
  RESULT_NOTES="${RESULT_NOTES}${3}|"
}

log()  { echo -e "${GREEN}[version-test]${NC} $1"; }
warn() { echo -e "${YELLOW}[version-test]${NC} $1"; }
fail() { echo -e "${RED}[version-test]${NC} $1"; }

# ---- Pre-flight checks ----

ENV_FILE="${PROJECT_DIR}/.env.docker"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.docker.example to .env.docker and fill in required values."
  exit 1
fi

cd "$PROJECT_DIR"

# All docker compose calls use the .env.docker file
dc() { docker compose --env-file "${ENV_FILE}" "$@"; }

NO_CACHE=""
if [[ "${1:-}" == "--no-cache" ]]; then
  NO_CACHE="--no-cache"
  log "Building with --no-cache"
fi

test_version() {
  local version="$1"
  local status="FAIL"
  local notes=""

  log "===== Testing OpenClaw v${version} ====="

  # Clean up from previous run
  dc down -v 2>/dev/null || true

  # Build with specific version
  log "Building image with OPENCLAW_VERSION=${version}..."
  if ! dc build ${NO_CACHE} --build-arg "OPENCLAW_VERSION=${version}" openclaw-agent 2>&1; then
    notes="build failed"
    add_result "$version" "$status" "$notes"
    return
  fi

  # Start services
  log "Starting services..."
  dc up -d 2>&1

  # Wait for agent health (up to 90s)
  log "Waiting for agent health..."
  local healthy=false
  for i in $(seq 1 90); do
    if dc exec -T openclaw-agent /usr/local/bin/openclaw-healthcheck >/dev/null 2>&1; then
      healthy=true
      log "Agent healthy after ${i}s"
      break
    fi
    sleep 1
  done

  if ! $healthy; then
    notes="health check timed out"
    # Capture logs for debugging
    log "Agent logs (last 30 lines):"
    dc logs --tail 30 openclaw-agent 2>&1 || true
    add_result "$version" "$status" "$notes"
    dc down -v 2>/dev/null || true
    return
  fi

  # Check entrypoint log markers (strip ANSI escape codes for reliable grep)
  local logs
  logs=$(dc logs openclaw-agent 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)

  local boot_ok=false
  local provider_ok=false
  local doctor_ok=false
  local ready_ok=false

  if echo "$logs" | grep -q "Booting agent:"; then
    boot_ok=true
  fi
  if echo "$logs" | grep -q "Provider setup complete"; then
    provider_ok=true
  fi
  if echo "$logs" | grep -qE "Doctor (completed|reported warnings)"; then
    doctor_ok=true
  fi
  if echo "$logs" | grep -q "\[openclaw-agent\].*Gateway launched"; then
    ready_ok=true
  fi

  # Run openclaw doctor explicitly
  local doctor_exit=false
  if dc exec -T openclaw-agent openclaw doctor --repair --non-interactive 2>&1; then
    doctor_exit=true
  fi

  # Determine result
  if $boot_ok && $provider_ok && $ready_ok; then
    status="PASS"
    notes=""
    if ! $doctor_ok; then
      notes="doctor log marker missing"
    fi
    if ! $doctor_exit; then
      notes="${notes:+${notes}; }explicit doctor returned non-zero"
    fi
  else
    local missing=""
    $boot_ok    || missing="${missing} boot"
    $provider_ok || missing="${missing} providers"
    $doctor_ok  || missing="${missing} doctor"
    $ready_ok   || missing="${missing} ready"
    notes="missing log markers:${missing}"
  fi

  add_result "$version" "$status" "$notes"

  # Cleanup
  dc down -v 2>/dev/null || true
  log "===== Finished v${version}: ${status} ====="
  echo ""
}

# ---- Run tests ----

for ver in $VERSIONS; do
  test_version "$ver"
done

# ---- Summary ----

echo ""
echo "========================================"
echo "  Version Compatibility Test Results"
echo "========================================"
printf "%-12s %-6s %s\n" "VERSION" "STATUS" "NOTES"
printf "%-12s %-6s %s\n" "-------" "------" "-----"

ALL_PASS=true
IFS='|' read -ra V_ARR <<< "$RESULT_VERSIONS"
IFS='|' read -ra S_ARR <<< "$RESULT_STATUSES"
IFS='|' read -ra N_ARR <<< "$RESULT_NOTES"

idx=0
for ver in $VERSIONS; do
  status="${S_ARR[$idx]:-FAIL}"
  notes="${N_ARR[$idx]:-}"
  if [[ "$status" == "PASS" ]]; then
    printf "%-12s ${GREEN}%-6s${NC} %s\n" "$ver" "$status" "$notes"
  else
    printf "%-12s ${RED}%-6s${NC} %s\n" "$ver" "$status" "$notes"
    ALL_PASS=false
  fi
  ((idx++)) || true
done

echo "========================================"
echo ""

if $ALL_PASS; then
  log "All versions passed"
  exit 0
else
  fail "Some versions failed"
  exit 1
fi
