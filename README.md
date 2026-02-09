# OpenClaw Cattle Mode

Containerized OpenClaw agent — immutable, disposable, replaceable. Run a single-purpose AI agent in a container with automatic backup/restore of all state. See [BLOG.md](BLOG.md) for the philosophy behind the cattle approach.

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

   Required values: `TELEGRAM_BOT_TOKEN`, `GRADIENT_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`

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
| `skills/` | Downloaded from config on boot — ephemeral |
| `openclaw.json` | Rendered from environment variables at boot — ephemeral |

### How it works

1. **First boot** (Spaces is empty): seed files from the image populate the workspace. The agent bootstraps and the backup watcher syncs everything to Spaces.
2. **Every subsequent boot**: the entrypoint restores `workspace/`, `agents/`, and `credentials/` from Spaces before starting the gateway. Seed files in the image are ignored — Spaces is the source of truth.
3. **While running**: an inotify watcher detects file changes and syncs them to Spaces with a 5-second debounce.
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

2. Redeploy:

   ```bash
   bash scripts/deploy.sh
   ```

## Environment Variables

| File | Purpose |
|------|---------|
| `.env.docker.example` | Template for local Docker Compose dev |
| `.env.remote.example` | Template for App Platform deploy |

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full rules on env files and deployment methods.

## Testing

```bash
# Test backup/restore cycle
bash scripts/test-backup.sh

# Test version compatibility
bash scripts/test-versions.sh
```

## Architecture

The container is built on `node:22-bookworm-slim` with OpenClaw installed via npm. At startup, the entrypoint script:

1. Generates `openclaw.json` from environment variables
2. Configures the Gradient provider and Telegram channel
3. Restores workspace, sessions, and credentials from S3-compatible storage
4. Runs `openclaw doctor` for migrations
5. Starts the gateway + backup watcher

If the container dies, nothing is lost — rebuild, inject the same env vars, and the agent comes back with full state intact.

See [BLOG.md](BLOG.md) for the detailed writeup.
