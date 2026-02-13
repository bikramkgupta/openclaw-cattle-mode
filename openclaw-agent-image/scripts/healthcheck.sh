#!/usr/bin/env bash
set -euo pipefail

# Minimal health check: ensure the gateway process exists.
# The regex dot matches both "openclaw-gateway" and "openclaw gateway".
if pgrep -f "openclaw.gateway" >/dev/null 2>&1; then
  echo "HEALTHY"
  exit 0
fi

echo "UNHEALTHY: openclaw gateway not running"
exit 1
