#!/usr/bin/env bash
set -euo pipefail

# Minimal health check: ensure the gateway process exists.
if pgrep -f "openclaw-gateway" >/dev/null 2>&1; then
  echo "HEALTHY"
  exit 0
fi

if ! pgrep -f "openclaw gateway" >/dev/null 2>&1; then
  echo "UNHEALTHY: openclaw gateway not running"
  exit 1
fi

echo "HEALTHY"
exit 0
