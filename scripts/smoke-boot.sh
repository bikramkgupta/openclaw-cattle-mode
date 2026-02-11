#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# smoke-boot.sh — Container boot smoke test for OpenClaw Cattle Mode
#
# Builds the agent image (default OpenClaw 2026.2.9), starts the Compose stack,
# waits for agent health, then tears down. Validates image build and entrypoint.
#
# Run locally (Docker + Docker Compose required). Not run in CI.
#
# Requirements:
#   - Docker + Docker Compose
#   - .env.docker populated with required values (TELEGRAM_BOT_TOKEN, GRADIENT_API_KEY, etc.)
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env.docker"

log()  { echo -e "${GREEN}[smoke]${NC} $1"; }
fail() { echo -e "${RED}[smoke]${NC} $1"; exit 1; }

dc() { docker compose --env-file "${ENV_FILE}" "$@"; }

cleanup() {
  log "Cleaning up..."
  cd "$PROJECT_DIR"
  dc down -v 2>/dev/null || true
}

# ---- Pre-flight ----

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.docker.example to .env.docker and fill in required values."
  exit 1
fi

trap cleanup EXIT
cd "$PROJECT_DIR"

# ---- Clean slate ----
log "Clean slate"
dc down -v 2>/dev/null || true

# ---- Build and start ----
log "Building and starting services"
dc up -d --build

# ---- Wait for health ----
log "Waiting for agent health (up to 90s)..."
for i in $(seq 1 90); do
  if dc exec -T openclaw-agent /usr/local/bin/openclaw-healthcheck >/dev/null 2>&1; then
    log "Agent healthy after ${i}s"
    exit 0
  fi
  sleep 1
done

fail "Agent did not become healthy within 90s"
