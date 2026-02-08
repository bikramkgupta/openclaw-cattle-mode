# OpenClaw Cattle Mode

Containerized OpenClaw agent — immutable, disposable, replaceable. Run a single-purpose AI agent in a container with automatic backup/restore of memory and credentials. See [BLOG.md](BLOG.md) for the philosophy behind the cattle approach.

## What You Get

- OpenClaw agent running in a container
- Telegram as the control channel
- Gradient (DigitalOcean AI) as the model provider
- Automatic backup/restore of agent memory and credentials
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

### 2. Deploy

**Option A — CLI:**

```bash
doctl apps create --spec app.yaml
```

**Option B — UI:**

Import the repo in [App Platform](https://cloud.digitalocean.com/apps) and use `app.yaml` as the spec.

### 3. Set Secrets

In the App Platform UI, set these as encrypted environment variables:

- `TELEGRAM_BOT_TOKEN`
- `GRADIENT_API_KEY`
- `OPENCLAW_GATEWAY_TOKEN`
- `SPACES_ACCESS_KEY_ID`
- `SPACES_SECRET_ACCESS_KEY`

See `.env.remote.example` for the full list of remote env vars.

## Updating

1. Rebuild the image:

   Run the **"Build and Push to GHCR"** workflow in GitHub Actions.

2. Redeploy:

   ```bash
   doctl apps create-deployment <app-id> --wait
   ```

## Environment Variables

| File | Purpose |
|------|---------|
| `.env.docker.example` | Template for local Docker Compose dev |
| `.env.remote.example` | Reference for App Platform env vars |
| `app.yaml` | Authoritative remote config (non-secrets) |

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
3. Restores workspace and runtime state from S3-compatible storage
4. Runs `openclaw doctor` for migrations
5. Starts the gateway + backup watcher

If the container dies, nothing is lost — rebuild, inject the same env vars, and the agent comes back with full memory intact.

See [BLOG.md](BLOG.md) for the detailed writeup.
