# Asset List (OpenClaw Cattle Mode)

This repo deploys an OpenClaw Gateway + Telegram bot as a **DigitalOcean App Platform Worker** using a **pre-built container image**.

## Source

- GitHub repo: https://github.com/bikramkgupta/openclaw-cattle-mode
- Default branch: `main`

## Docker Images

### Production — GHCR (GitHub Container Registry)

- Image: `ghcr.io/bikramkgupta/openclaw-agent:latest`
- Build context / Dockerfile: `openclaw-agent-image/Dockerfile`
- CI workflow: `.github/workflows/ghcr-build-push.yml`
- Tagging behavior (from CI):
  - `latest` is pushed on the default branch
  - a git-SHA tag is always pushed (useful for pinning/rollback)
- Visibility: **public** (no registry credentials needed to pull)

### Production — DOCR (DigitalOcean Container Registry)

- Image: `registry.digitalocean.com/openclaw/openclaw-agent:latest`
- CI workflow: `.github/workflows/build-push.yml`
- Tagging: same as GHCR (latest + SHA)
- Note: DOCR workflow is kept as a fallback; `app.yaml` now points to GHCR

### Local Dev (Docker Compose)

Defined in `docker-compose.yml`:

- `openclaw-agent` (built locally from `openclaw-agent-image/`)
- `rustfs/rustfs:1.0.0-alpha.82` (override via `RUSTFS_IMAGE`)
- `amazon/aws-cli:2.15.57` (bucket bootstrap helper)
- `busybox:1.36` (init helper)

## DigitalOcean App Platform

- App name: `openclaw-v0`
- App ID: `f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59`
- Region: `syd`
- Component: Worker `openclaw-agent`
- App spec in repo (non-secret): `app.yaml`
- App URL (UI): https://cloud.digitalocean.com/apps/f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59

## Telegram

- Bot: https://t.me/Basic_claw_bot
- Access control:
  - `TELEGRAM_ALLOWFROM="6944791786"` (DM allowlist)
  - `TELEGRAM_BOT_TOKEN` is stored as an App Platform **secret** (do not commit)

## Environment Variables

### Local

- Template: `.env.docker.example`
- Local-only files (gitignored): `.env.docker`, `.env.local`
- Local S3 endpoint (RustFS): `S3_ENDPOINT_URL=http://rustfs:9000` (see `.env.docker.example`)
- Usage: `docker compose --env-file .env.docker up -d`

### Remote (App Platform)

- Reference template: `.env.remote.example`
- Local copy (gitignored): `.env.remote`
- Authoritative list of keys: `app.yaml` under `workers[0].envs`

Secrets (set in DO App Platform UI, do not commit):

- `TELEGRAM_BOT_TOKEN`
- `GRADIENT_API_KEY`
- `OPENCLAW_GATEWAY_TOKEN`
- `SPACES_ACCESS_KEY_ID`
- `SPACES_SECRET_ACCESS_KEY`

Non-secrets (kept in `app.yaml`):

- `AGENT_ID`, `AGENT_NAME`
- `TELEGRAM_ALLOWFROM`
- `AGENT_DEFAULT_MODEL`
- `NODE_OPTIONS`
- `SPACES_BUCKET`, `SPACES_REGION`

## How To Update

### 1) Build + Push a New Image

Preferred: run the GitHub Actions workflow `.github/workflows/ghcr-build-push.yml` ("Build and Push to GHCR").

Fallback: run `.github/workflows/build-push.yml` ("Build and Push to DOCR").

Notes:

- App Platform uses the `:latest` tag in `app.yaml`.
- CI also publishes a SHA tag for pinning/rollback.

### 2) Redeploy the App Platform Worker

Option A (UI): App Platform -> `openclaw-v0` -> "Deploy" / "Redeploy".

Option B (CLI):

```bash
doctl apps create-deployment f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --wait
```

### 3) Update Remote Config (non-secret)

Edit `app.yaml`, then:

```bash
doctl apps update f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --spec app.yaml --wait
```

### 4) Update Remote Secrets (Telegram token, API keys, etc.)

Preferred: update in the App Platform UI under the app's Environment Variables/Secrets, then redeploy.

CLI alternative: avoid writing secrets into `app.yaml` by piping a spec via stdin:

```bash
# Warning: `doctl apps spec get` includes encrypted placeholders (`EV[...]`) for secrets.
# Those placeholders are NOT accepted if you try to round-trip them back into `apps update`.
# If you use the CLI, you must provide plaintext `value:` entries for every secret you want
# to keep (or use the UI instead so you don't accidentally wipe secrets).
#
# Avoid committing secrets: do not write the rendered spec back to the repo.
doctl apps spec get f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --format yaml > /tmp/openclaw-v0.spec.yaml
# Edit /tmp/openclaw-v0.spec.yaml to replace each secret env var's `value:` with plaintext, then:
doctl apps update f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --spec /tmp/openclaw-v0.spec.yaml --wait
```

## Ops / Debug

### Logs

```bash
doctl apps logs f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 openclaw-agent --type run --tail 200
doctl apps logs f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 openclaw-agent --type deploy --tail 200
```

### Confirm Effective Spec (includes encrypted secret placeholders)

```bash
doctl apps spec get f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --format yaml
```
