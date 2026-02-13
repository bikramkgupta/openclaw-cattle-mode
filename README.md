# OpenClaw Cattle Mode

[![Nightly](https://github.com/bikramkgupta/openclaw-cattle-mode/actions/workflows/nightly.yml/badge.svg)](https://github.com/bikramkgupta/openclaw-cattle-mode/actions/workflows/nightly.yml)
[![Integration](https://github.com/bikramkgupta/openclaw-cattle-mode/actions/workflows/integration.yml/badge.svg)](https://github.com/bikramkgupta/openclaw-cattle-mode/actions/workflows/integration.yml)
[![OpenClaw Version](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/bikramkgupta/openclaw-cattle-mode/main/.github/badges/version.json)](https://github.com/bikramkgupta/openclaw-cattle-mode)

Containerized OpenClaw agent — immutable, disposable, replaceable. Run a single-purpose AI agent in a container with automatic backup/restore of all state. See the [blog post](https://www.linkedin.com/pulse/case-running-openclaw-containers-bikram-gupta-ngc2c/) for the philosophy behind the cattle approach.

## What You Get

- OpenClaw agent running in a container
- Telegram as the control channel
- Gradient (DigitalOcean AI) as the model provider
- Automatic backup/restore of agent workspace, sessions, and credentials
- Local dev with Docker Compose + RustFS (local S3)
- Cloud deploy to DigitalOcean App Platform

## Prerequisites

- Docker + Docker Compose
- A Telegram bot token (via [@BotFather](https://t.me/BotFather))
- A Gradient API key (via [DigitalOcean](https://cloud.digitalocean.com/gen-ai/gradient))

## Run Locally

1. Clone the repo:

   ```bash
   git clone https://github.com/bikramkgupta/openclaw-cattle-mode.git
   cd openclaw-cattle-mode
   ```

2. Copy `.env.docker.example` to `.env.docker` and fill in your secrets:

   ```bash
   cp .env.docker.example .env.docker
   ```

   Required values: `TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, and at least one provider key (`GRADIENT_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY`)

   Generate a gateway token:

   ```bash
   openssl rand -hex 32
   ```

3. Start everything:

   ```bash
   docker compose --env-file .env.docker up -d
   ```

4. Send a message to your Telegram bot. The agent will respond.

### Local Architecture

Docker Compose starts four services:

- **openclaw-agent** — the AI agent (built from `openclaw-agent-image/`)
- **rustfs** — local S3-compatible store for backup/restore
- **rustfs-bucket** — creates the default bucket on first run
- **rustfs-init** — sets volume permissions

## Run on App Platform

### 1. Create a Spaces Bucket + Keys

```bash
bash scripts/setup-spaces.sh
```

Or manually: create a Spaces bucket in the [DigitalOcean console](https://cloud.digitalocean.com/spaces) and generate access keys under API > Spaces Keys.

### 2. Configure Environment

```bash
cp .env.remote.example .env.remote
# Fill in all values (see DEPLOYMENT.md for details)
```

### 3. Deploy

```bash
bash scripts/deploy.sh
```

The deploy script reads `.env.remote`, substitutes values into `app.yaml`, deploys via `doctl`, and cleans up. See [DEPLOYMENT.md](DEPLOYMENT.md) for the full deployment reference.

Preview without deploying:

```bash
bash scripts/deploy.sh --dry-run
```

## How Backup/Restore Works

**Spaces (S3) is the brain. The container is just bones.**

The agent's entire runtime state is continuously synced to a Spaces bucket. When the container restarts or redeploys, state is restored from Spaces. The container itself is disposable.

### What gets backed up

| Directory | Contents |
|-----------|----------|
| `workspace/` | `AGENTS.md`, `SOUL.md`, `USER.md`, `IDENTITY.md`, `memory/`, `MEMORY.md`, and everything else the agent creates |
| `agents/` | Session transcripts, auth profiles, model registry — for all agent IDs (supports multi-agent) |
| `credentials/` | OAuth tokens, API keys |

### What does NOT get backed up

| Directory | Why |
|-----------|-----|
| `openclaw.json` | Rendered from environment variables at boot — ephemeral |

### How it works

1. **First boot** (Spaces is empty): seed files from the image populate the workspace. The agent bootstraps and the backup watcher syncs everything to Spaces.
2. **Every subsequent boot**: the entrypoint restores `workspace/`, `agents/`, and `credentials/` from Spaces before starting the gateway. Seed files in the image are ignored — Spaces is the source of truth.
3. **While running**: a periodic sync runs every 60 seconds, pushing changes to Spaces.
4. **On shutdown**: a final backup runs before the container exits.

### Updating workspace files

Because Spaces is the source of truth, you update workspace files by pushing them to Spaces — not by rebuilding the image.

```bash
# Upload a single file (e.g., updated AGENTS.md)
bash scripts/push-workspace.sh AGENTS.md

# Upload an entire directory
bash scripts/push-workspace.sh workspace/

# List current workspace files in Spaces
bash scripts/push-workspace.sh --list
```

Changes take effect on the next container restart or redeploy.

## Updating the Image

1. Rebuild the image:

   Run the **"Build and Push to GHCR"** workflow in GitHub Actions.

2. Set the deploy tag in `.env.remote`: `IMAGE_TAG=2026.2.12` (or the version you built). This controls which image tag App Platform pulls.

3. Redeploy:

   ```bash
   bash scripts/deploy.sh
   ```

## Supported Versions

| OpenClaw Version | Image Tag | Status | Notes |
|------------------|-----------|--------|-------|
| `2026.2.12` | `2026.2.12` | **Current** | — |
| `2026.2.9`  | `2026.2.9`  | Tested | Telegram plugin fix auto-applied |
| `2026.2.6` | `2026.2.6` | Tested | Previous stable release |
| `2026.2.3` | `2026.2.3` | Tested | — |
| `2026.2.2` | `2026.2.2` | Tested | — |
| `2026.2.1` | `2026.2.1` | Tested | Earliest supported |

The `IMAGE_TAG` in `.env.remote` / `.env.docker` must match an image that has been built and pushed to GHCR. Use the GHCR build workflow to build a new version:

```bash
gh workflow run ghcr-build-push.yml -f openclaw_version=<version>
```

## Memory Budget

The agent runs on a 1cpu/1gb instance. Here's how the ~1024MB is used:

| Component | Typical RSS | Notes |
|-----------|-------------|-------|
| `openclaw` (CLI parent) | ~130 MB | Spawns and supervises the gateway |
| `openclaw-gateway` | ~470 MB | V8 heap + WebSocket + Telegram polling |
| OS + Node runtime | ~50 MB | Shared libs, kernel buffers |
| **Available headroom** | **~370 MB** | For spikes during doctor, subagents, tool calls |

### Tuning `NODE_OPTIONS`

The V8 heap limit is set via `NODE_OPTIONS=--max-old-space-size=<MB>`:

| Instance | Recommended | Why |
|----------|-------------|-----|
| 1cpu/1gb | `768` | 512 OOMs during `openclaw doctor`; 768 leaves room for gateway |
| 1cpu/2gb | `1536` | Comfortable margin for subagents and large tool outputs |

### What causes OOM

- Long-running sessions accumulating context (no automatic eviction)
- Multiple concurrent subagents (each holds its own context window)
- Large tool outputs (file reads, web fetches) buffered in memory
- `openclaw doctor` at startup (briefly spikes memory)

The daily gateway restart (see Architecture) mitigates slow leaks.

## Environment Variables

| File | Purpose |
|------|---------|
| `.env.docker.example` | Template for local Docker Compose dev |
| `.env.remote.example` | Template for App Platform deploy |

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full rules on env files and deployment methods.

## Testing

All tests except the deploy-spec check run **locally** (Docker + Docker Compose). CI only runs the deploy-spec test (no Docker in GitHub Actions).

| Test | Command | Where |
|------|---------|--------|
| Container boot (smoke) | `bash scripts/smoke-boot.sh` | Local |
| Backup and restore | `bash scripts/test-backup.sh` | Local |
| Deploy spec render | `bash scripts/test-deploy-spec.sh` | Local or CI |
| Version compatibility | `bash scripts/test-versions.sh` | Local |

Run all locally (in order):

```bash
bash scripts/smoke-boot.sh && \
bash scripts/test-deploy-spec.sh && \
bash scripts/test-backup.sh && \
bash scripts/test-versions.sh
```

## Connecting WhatsApp

WhatsApp uses QR-based linking (no bot token). Three steps:

**1. Add your phone number to `.env.remote` and deploy:**

```bash
# In .env.remote, set your number (E.164 format):
WHATSAPP_ALLOWFROM=+14085551234

# Deploy
bash scripts/deploy.sh
```

The entrypoint auto-configures `channels.whatsapp` with `dmPolicy: "allowlist"` and `selfChatMode: true`. Only your number can talk to the bot.

**2. Connect to the container and scan the QR code:**

```bash
doctl apps console <app-id> openclaw-agent
# Inside the container:
openclaw channels login
```

Scan the QR from your phone: WhatsApp → Settings → Linked Devices → Link a Device.

**3. If the gateway doesn't pick up the connection, restart the container:**

```bash
bash scripts/deploy.sh
```

Credentials are persisted to `~/.openclaw/credentials/whatsapp/` and backed up to S3 automatically. On subsequent restarts, WhatsApp reconnects without scanning again.

## Architecture

The container is built on `node:24-bookworm-slim` with OpenClaw installed via npm. At startup, the entrypoint script:

1. Generates `openclaw.json` from environment variables
2. Configures the Gradient provider, Telegram, and WhatsApp channels
3. Restores workspace, sessions, and credentials from S3-compatible storage
4. Runs `openclaw doctor` for migrations (skipped on same-version reboots)
5. Re-asserts Telegram plugin state (2026.2.9+ fix, only after doctor)
6. Installs skills from ClawHub (skipped if already present from S3 restore)
7. Starts the gateway + backup watcher

If the container dies, nothing is lost — rebuild, inject the same env vars, and the agent comes back with full state intact.

See the [blog post](https://www.linkedin.com/pulse/case-running-openclaw-containers-bikram-gupta-ngc2c/) for the detailed writeup.
