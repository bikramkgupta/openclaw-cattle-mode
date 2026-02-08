OpenClaw V0 Build Tasks (Telegram-First)

Status: V0 task list aligned to `SPEC.md` and the current repo scaffold.

This file is meant to be buildable: each task maps directly to code under this repo.

---

## V0 Goal

Produce a minimal OpenClaw agent container that:

- Runs on DigitalOcean App Platform as a 1cpu/1gb Worker
- Runs locally via Docker Compose
- Uses Telegram as the primary control channel (Telegram-only in V0)
- Uses Gradient for models (required) and supports optional OpenAI/Anthropic API keys
- Restores workspace + runtime state from S3-compatible storage and backs up runtime state continuously

Pinned versions:

- OpenClaw: `openclaw@2026.2.6`

---

## V0 Task List

### Task V0.1: Minimal Agent Image Folder

Goal:

- Create the minimal container image that can run `openclaw gateway` as a non-root user.

Work:

- Create `/Users/bikram/Documents/Build/biz-openclaw/openclaw-agent-image/`
- Add:
  - `Dockerfile`
  - `config/openclaw.base.json`
  - `scripts/entrypoint.sh`
  - `scripts/setup-providers.sh`
  - `scripts/setup-channels.sh`
  - `scripts/restore.sh`
  - `scripts/backup.sh`
  - `scripts/healthcheck.sh`

Acceptance:

- `docker build` succeeds
- Image runs as non-root
- `openclaw gateway` starts and stays running
- SIGTERM triggers a final backup and exits cleanly

---

### Task V0.2: Runtime Config Generation (`OPENCLAW_CONFIG_PATH`)

Goal:

- Generate config at startup and keep it ephemeral.

Work:

- Render base config template to:
  - `OPENCLAW_CONFIG_PATH=/run/openclaw/openclaw.json`
- Enforce permissions:
  - `0600`
- Ensure config is regenerated every start.

Acceptance:

- Config file exists at runtime with `0600`
- Config file is not written to object storage
- No secret values are logged (do not `cat` the config in logs)

---

### Task V0.3: Telegram Wiring (Telegram-First Contract)

Goal:

- Telegram works with pairing by default, allowlist when configured.

Work:

- Inputs:
  - `TELEGRAM_BOT_TOKEN` (required)
  - `TELEGRAM_ALLOWFROM` (optional)
- Behavior:
  - If `TELEGRAM_ALLOWFROM` set: `dmPolicy=allowlist` and populate `allowFrom`
  - Else: `dmPolicy=pairing`

Acceptance:

- Bot receives DMs
- Allowlisted IDs can talk to the bot when allowlist is set
- When allowlist is empty, pairing mode is used (not open)

---

### Task V0.4: Provider Wiring (Gradient Required; OpenAI/Anthropic Optional)

Goal:

- Configure Gradient provider and select a default model deterministically.

Work:

- Required:
  - `GRADIENT_API_KEY`
- Optional:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
- Default model selection:
  - If `AGENT_DEFAULT_MODEL` is set: use it
  - Else: `gradient/anthropic-claude-opus-4.6`

Acceptance:

- When `GRADIENT_API_KEY` is present, config contains the Gradient provider
- Default model is set to `gradient/anthropic-claude-opus-4.6` unless overridden by `AGENT_DEFAULT_MODEL`

---

### Task V0.5: Restore From Object Storage (Spaces/RustFS)

Goal:

- Restore the workspace + runtime state into `OPENCLAW_STATE_DIR` before the gateway starts.

Work:

- Object store prefix:
  - `s3://$SPACES_BUCKET/openclaw/$AGENT_ID/`
- Restore workspace config files if present (customer-seeded; never overwritten by backup):
  - `workspace/AGENTS.md`
  - `workspace/SOUL.md`
  - `workspace/USER.md`
  - `workspace/TOOLS.md`
  - `workspace/IDENTITY.md`
  - `workspace/HEARTBEAT.md`
- Restore runtime state:
  - `workspace/memory/`
  - `workspace/MEMORY.md`
  - `credentials/`

Acceptance:

- If files exist in the bucket, they appear under `OPENCLAW_STATE_DIR/…` after restart
- If not present, OpenClaw still runs using its defaults

---

### Task V0.6: Selective Backup To Object Storage

Goal:

- Back up runtime state continuously, without overwriting customer-seeded workspace files.

Work:

- Back up only:
  - `workspace/memory/`
  - `workspace/MEMORY.md`
  - `credentials/`
- Use inotify when available; fall back to polling.
- Perform a final backup on shutdown.

Acceptance:

- Runtime state changes appear in the bucket prefix
- Workspace config files (`AGENTS.md`, `SOUL.md`, etc.) are never overwritten by backup

---

### Task V0.7: Local Docker Compose Environment (Agent + Local S3)

Goal:

- One command boots local S3-compatible storage + agent.

Work:

- Add repo-root:
  - `docker-compose.yml`
  - `.env.example`
- Compose services:
  - `rustfs` (S3-compatible endpoint; scaffold defaults to `rustfs/rustfs`)
  - `rustfs-init` (chown data volume; required by some non-root S3 images)
  - `rustfs-bucket` (ensure bucket exists)
  - `openclaw-agent`

Acceptance:

- `docker compose up -d` starts all services successfully
- Restarting `openclaw-agent` restores state from the local object store

---

### Task V0.8: DigitalOcean App Platform Scaffold (No Deploy Yet)

Goal:

- Provide a DO App Platform spec that matches the V0 contract and uses 1cpu/1gb.

Work:

- Add repo-root `app.yaml` with:
  - `instance_size_slug: apps-s-1vcpu-1gb-fixed`
  - Telegram + provider + Spaces env var keys (including OpenAI/Anthropic)

Acceptance:

- `app.yaml` is ready for later use once you publish an image and fill in placeholders

---

## Manual Test Cases (V0 Acceptance)

1. Local boot
- `docker compose up -d`
- Verify `openclaw-agent` stays running and passes healthcheck

2. Telegram
- Send a DM to the bot
- If `TELEGRAM_ALLOWFROM` is set, verify non-allowlisted user is not accepted

3. Restore
- Put `workspace/SOUL.md` into the bucket under `openclaw/<agent-id>/workspace/SOUL.md`
- Restart the container
- Verify file exists under `OPENCLAW_STATE_DIR/workspace/SOUL.md`

4. Backup
- Write a file under `OPENCLAW_STATE_DIR/workspace/memory/YYYY-MM-DD.md`
- Verify it appears under `workspace/memory/` in the bucket prefix

5. Providers
- With `GRADIENT_API_KEY` set, verify default model becomes `gradient/anthropic-claude-opus-4.6` (unless overridden)
- With `OPENAI_API_KEY` and/or `ANTHROPIC_API_KEY` set, verify the config includes those providers (default model stays Gradient unless overridden)

---

## Backlog (Post-V0)

- Git-as-identity (repo-per-agent)
- Orchestrator service (agent registry + secrets + deploy)
- Multi-agent templates
- Optional sandbox-browser support
