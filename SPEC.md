OpenClaw V0 Agent Container (Telegram-First)

Status: Authoritative V0 spec (scaffold-ready)

This document describes the V0 build that exists in this repo today:

- A minimal OpenClaw agent container (OpenClaw pinned to `openclaw@2026.2.6`)
- Telegram-first channel configuration (Telegram only in V0)
- Gradient provider (required) plus optional OpenAI + Anthropic API keys
- Workspace + runtime state restored/backed up via S3-compatible object storage
  - DigitalOcean Spaces in prod
  - RustFS-compatible endpoint in local Docker Compose
- No orchestrator, no Git identity, no deployment automation in V0

---

## 1. V0 Scope (Ship Now)

### What ships

- One container: `openclaw-agent`
- Runs: `openclaw gateway`
- Channel: Telegram only
- Providers:
  - Gradient (required)
  - OpenAI + Anthropic API keys supported (optional)
- Object store restore/backup:
  - Restore workspace files + runtime state at startup
  - Backup runtime state continuously, and on shutdown
- Local dev: `docker compose up` (agent + local S3-compatible service)
- Platform target: DigitalOcean App Platform (1cpu/1gb instance)

### What is explicitly out of scope in V0

- Orchestrator backend
- Git provisioning / Git-as-identity
- Multi-agent templates
- Multi-replica agents / Kubernetes
- sandbox-browser service
- Observability stack (OTEL, OpenSearch)

---

## 2. Invariants (Do Not Break)

1. One agent = one runtime instance
2. Secrets are runtime inputs (env vars), never committed
3. `openclaw.json` is generated at startup and is not persisted to object storage
4. Workspace + runtime state are restored from object storage before the gateway starts
5. Backup is selective: runtime state only; customer-seeded workspace files are never overwritten

---

## 3. Public Interface (Env Vars Contract)

Order is intentional: Telegram-first.

### Telegram (required)

- `TELEGRAM_BOT_TOKEN` (required)
- `TELEGRAM_ALLOWFROM` (optional; comma-separated Telegram user IDs)
  - If set: Telegram DM policy is allowlist
  - If empty: Telegram DM policy is pairing (not open)

### Providers

- `GRADIENT_API_KEY` (required)
- `OPENAI_API_KEY` (optional)
- `ANTHROPIC_API_KEY` (optional)
- `AGENT_DEFAULT_MODEL` (optional override; otherwise defaults to `gradient/anthropic-claude-opus-4.6`)

### Identity + gateway auth

- `AGENT_ID` (required; example `agent-dev`)
- `AGENT_NAME` (optional)
- `OPENCLAW_GATEWAY_TOKEN` (required)

### Object store (Spaces in prod, RustFS locally)

- `SPACES_BUCKET` (required)
- `SPACES_REGION` (required)
- `SPACES_ACCESS_KEY_ID` (required)
- `SPACES_SECRET_ACCESS_KEY` (required)
- `S3_ENDPOINT_URL` (optional override; required for local Compose)

### Runtime paths (authoritative defaults)

- `OPENCLAW_STATE_DIR=/home/openclaw/.openclaw`
- `OPENCLAW_CONFIG_PATH=/run/openclaw/openclaw.json` (ephemeral config file)

---

## 4. Architecture (V0)

### Components

- `openclaw-agent` container
  - Generates `OPENCLAW_CONFIG_PATH` at startup
  - Restores workspace + runtime state from object storage
  - Runs `openclaw gateway`
  - Continuously backs up runtime state to object storage

- Object store (S3-compatible)
  - DigitalOcean Spaces in prod
  - RustFS-compatible endpoint in local dev

No other services are required in V0.

---

## 5. Object Store Layout (Authoritative)

Prefix:

`s3://$SPACES_BUCKET/openclaw/$AGENT_ID/`

### Customer-seeded workspace files (restored if present; never overwritten by backup)

- `workspace/AGENTS.md`
- `workspace/SOUL.md`
- `workspace/USER.md`
- `workspace/TOOLS.md`
- `workspace/IDENTITY.md`
- `workspace/HEARTBEAT.md`

### Runtime state (restored and backed up)

- `workspace/memory/`
- `workspace/MEMORY.md`
- `credentials/`

Notes:

- `openclaw.json` is not stored in object storage.
- Runtime backup intentionally excludes the workspace config files listed above.

---

## 6. Configuration Model (Generated `openclaw.json`)

### Rules

- Config file path: `OPENCLAW_CONFIG_PATH` (default `/run/openclaw/openclaw.json`)
- File mode: `0600`
- Always regenerated at startup
- Never uploaded to object storage

### Contents (V0 minimum)

- Gateway defaults (bind/mode) plus runtime flags provided via CLI at launch
- Telegram channel configured from `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWFROM`
- Gradient provider configured from `GRADIENT_API_KEY`
- Default model selection logic (override first; else `gradient/anthropic-claude-opus-4.6`)

---

## 7. Startup Sequence (V0)

1. Validate required env vars
2. Render base config template to `OPENCLAW_CONFIG_PATH`
3. Apply provider configuration
4. Apply Telegram configuration
5. Restore workspace + runtime state from object storage into `OPENCLAW_STATE_DIR`
6. Run `openclaw doctor --repair --non-interactive` (safe, idempotent)
7. Start `openclaw gateway`
8. Start selective backup watcher
9. On shutdown: perform a final backup sync

---

## 8. Local Development (Docker Compose + RustFS-Compatible S3)

Local dev uses:

- `docker-compose.yml` at repo root
- `.env.example` at repo root

Assumptions:

- Local S3-compatible endpoint is `http://rustfs:9000`
- Bucket is created during Compose startup

Local flow:

1. Set secrets in `.env` (copy from `.env.example`)
2. Run `docker compose up -d`
3. Verify the gateway stays running and Telegram responds

---

## 9. DigitalOcean App Platform Notes (V0)

- Target instance size: `apps-s-1vcpu-1gb-fixed` (1cpu/1gb)
- Run as a Worker by default (Telegram long polling requires no inbound HTTP)
- Container runs as non-root (`openclaw` user)
- If Control UI access is desired later:
  - Deploy as a Service instead of Worker
  - Keep `OPENCLAW_GATEWAY_TOKEN` required

Scaffold file:

- `app.yaml` (example only; not deployed yet)

---

## 10. Future (Post-V0)

When V0 is stable:

- Git-as-identity (repo per agent)
- Orchestrator (agent registry + secrets + deploy)
- Persona templates and multi-agent support
- Optional sandbox-browser and other platform integrations
