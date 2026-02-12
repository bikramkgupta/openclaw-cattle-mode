#!/usr/bin/env bash
# Fetch OpenClaw documentation for a specific version from GitHub.
#
# Usage:
#   bash scripts/fetch-openclaw-doc.sh channels/whatsapp.md
#   bash scripts/fetch-openclaw-doc.sh channels/whatsapp.md 2026.2.9
#   bash scripts/fetch-openclaw-doc.sh --list channels
#   bash scripts/fetch-openclaw-doc.sh --list
#
# Version resolution (in order):
#   1. Explicit second argument
#   2. IMAGE_TAG from .env.remote
#   3. IMAGE_TAG from .env.docker
#   4. Falls back to "main" branch
set -euo pipefail

REPO="openclaw/openclaw"
DOCS_PREFIX="docs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[fetch-doc]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[fetch-doc]${NC} $1" >&2; }

resolve_version() {
  local version="${1:-}"

  if [[ -n "${version}" ]]; then
    echo "v${version#v}"
    return
  fi

  # Try .env.remote first, then .env.docker
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local root_dir="${script_dir}/.."

  for envfile in "${root_dir}/.env.remote" "${root_dir}/.env.docker"; do
    if [[ -f "${envfile}" ]]; then
      local tag
      tag="$(grep -E '^IMAGE_TAG=' "${envfile}" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || true)"
      if [[ -n "${tag}" ]]; then
        echo "v${tag#v}"
        return
      fi
    fi
  done

  warn "No version found — using main branch"
  echo "main"
}

list_docs() {
  local ref="$1"
  local path="${2:-}"
  local full_path="${DOCS_PREFIX}"
  [[ -n "${path}" ]] && full_path="${DOCS_PREFIX}/${path}"

  log "Listing ${full_path}/ at ${ref}"
  gh api "repos/${REPO}/contents/${full_path}?ref=${ref}" --jq '.[] | select(.type == "dir") .name + "/", select(.type == "file") .name' 2>&1
}

fetch_doc() {
  local ref="$1"
  local doc_path="$2"
  local full_path="${DOCS_PREFIX}/${doc_path}"

  # Add .md extension if missing
  if [[ "${full_path}" != *.md ]]; then
    full_path="${full_path}.md"
  fi

  log "Fetching ${full_path} at ${ref}"
  gh api "repos/${REPO}/contents/${full_path}?ref=${ref}" --jq '.content' 2>&1 | base64 -d
}

main() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: bash scripts/fetch-openclaw-doc.sh <doc-path> [version]"
    echo "       bash scripts/fetch-openclaw-doc.sh --list [subdir] [version]"
    echo ""
    echo "Examples:"
    echo "  bash scripts/fetch-openclaw-doc.sh channels/whatsapp"
    echo "  bash scripts/fetch-openclaw-doc.sh channels/telegram 2026.2.9"
    echo "  bash scripts/fetch-openclaw-doc.sh --list channels"
    echo "  bash scripts/fetch-openclaw-doc.sh --list"
    exit 1
  fi

  if [[ "$1" == "--list" ]]; then
    local subdir="${2:-}"
    local version
    version="$(resolve_version "${3:-}")"
    list_docs "${version}" "${subdir}"
  else
    local doc_path="$1"
    local version
    version="$(resolve_version "${2:-}")"
    fetch_doc "${version}" "${doc_path}"
  fi
}

main "$@"
