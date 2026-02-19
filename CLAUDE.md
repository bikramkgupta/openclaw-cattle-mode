# OpenClaw Cattle Mode

## Architecture

Containerized OpenClaw AI agent on DigitalOcean App Platform (1cpu/1gb worker).
Channels: Telegram + WhatsApp. Provider: Gradient. State: S3 backup/restore.

```
┌─────────────────────────────────────────────────────────┐
│  App Platform Worker (apps-s-1vcpu-1gb, syd region)     │
│  ┌───────────────────────────────────────────────────┐  │
│  │  openclaw-agent container (node:22-bookworm-slim) │  │
│  │  - entrypoint.sh boots: config → restore → doctor │  │
│  │    → plugins → skills → gateway + backup watcher  │  │
│  │  - Telegram (long-poll) + WhatsApp (Baileys)      │  │
│  │  - Periodic S3 sync (60s) + shutdown backup       │  │
│  └───────────────────────────────────────────────────┘  │
│  Image: ghcr.io/bikramkgupta/openclaw-agent:<tag>       │
└────────────────────┬────────────────────────────────────┘
                     │ S3 backup/restore
                     ▼
           DigitalOcean Spaces (syd1)
```

Cattle approach: containers are disposable, S3 is the brain. Skills reinstall on every boot.

### Production

- **App name:** `openclaw-v0`
- **App ID:** `f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59`
- **Region:** syd
- **Instance:** `apps-s-1vcpu-1gb`

## Key Files

| File | Purpose |
|------|---------|
| `openclaw-agent-image/scripts/entrypoint.sh` | Boot sequence |
| `openclaw-agent-image/Dockerfile` | Container image build |
| `app.yaml` | App Platform spec template (`${VAR}` placeholders) |
| `app-nightly-test.yaml` | Ephemeral nightly test app spec |
| `scripts/deploy.sh` | Deploy to App Platform from `.env.remote` |
| `scripts/test-backup.sh` | Full E2E backup/restore test |
| `scripts/smoke-boot.sh` | Smoke test (boot + health check) |
| `DEPLOYMENT.md` | Deployment rules, env files, secrets |

## OpenClaw Documentation

Always look up upstream docs before implementing OpenClaw configuration changes:

```bash
bash scripts/fetch-openclaw-doc.sh channels/whatsapp       # auto-detects version
bash scripts/fetch-openclaw-doc.sh channels/telegram
bash scripts/fetch-openclaw-doc.sh --list channels          # list available docs
bash scripts/fetch-openclaw-doc.sh gateway/security 2026.2.9  # specific version
```

## Deploying to App Platform

Use the `do-app-platform-skills` skill for App Platform tasks (migrations, networking, troubleshooting).

**Image rebuild vs deploy-only:** `deploy.sh` only updates the app spec — it does NOT rebuild the Docker image. Any change under `openclaw-agent-image/` (scripts, Dockerfile, config) requires an image rebuild first:

```bash
# Image changes: rebuild first, then deploy
gh workflow run ghcr-build-push.yml -f openclaw_version=2026.2.12
gh run watch   # wait for build
bash scripts/deploy.sh

# Spec/env-only changes: deploy directly
bash scripts/deploy.sh
```

### Local deploy

```bash
# Populate .env.remote from .env.remote.example, then:
bash scripts/deploy.sh            # deploy
bash scripts/deploy.sh --dry-run  # preview rendered spec
```

### CI deploy (manual trigger)

```bash
gh workflow run integration.yml -f run_deploy=true
```

Requires `DIGITALOCEAN_TOKEN` + all `.env.remote` vars as GitHub secrets.

### Logs and console

```bash
doctl apps logs f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 --type run
doctl apps console f1ce3e9e-3ecf-44d9-a3bd-65222f42ff59 openclaw-agent
```

## CI/CD Pipelines

### Integration (`integration.yml`) — on push/PR to main

1. **deploy-spec** — validates `app.yaml` renders without unsubstituted vars
2. **container-test** — boots agent with Docker Compose + local RustFS
   - If `GRADIENT_API_KEY` secret is set: full E2E (`test-backup.sh`)
   - Otherwise: smoke only (`smoke-boot.sh`)
   - Telegram and WhatsApp are **excluded from CI** to avoid conflicting with production (Telegram allows only one poller per token)
3. **deploy** — manual trigger only, deploys to App Platform

### Nightly (`nightly.yml`) — 11 PM Pacific daily

1. **check-version** — compares Dockerfile version vs npm latest
2. **build-image** — builds + pushes new GHCR image if version changed
3. **update-production** — updates live app spec and deploys
4. **test-fresh-install** — creates ephemeral App Platform instance, verifies boot markers, then deletes it. No Telegram/WhatsApp (avoids production conflicts).
5. **cleanup** — deletes ephemeral app
6. **report** — summary + version badge + Telegram failure notification

### GHCR build (`ghcr-build-push.yml` / reusable)

```bash
gh workflow run ghcr-build-push.yml -f openclaw_version=2026.2.12
```

## Security Rules

- **NEVER commit real secrets, tokens, phone numbers, or personal data** to any tracked file — including `.example` files. This is a **public repo**.
- Secrets go in gitignored files (`.env.docker`, `.env.remote`) or GitHub Secrets only.
- Always verify repo visibility before assessing data exposure risk: `gh repo view --json isPrivate`

## Environment Files

| File | Gitignored | Used by |
|------|-----------|---------|
| `.env.docker` | Yes | `docker compose` (local dev) |
| `.env.docker.example` | No | Template for `.env.docker` |
| `.env.remote` | Yes | `scripts/deploy.sh` (production) |
| `.env.remote.example` | No | Template for `.env.remote` |

See `DEPLOYMENT.md` for full env var reference and adding new variables.

## File Map

```
vision.md        ← Problem, users, outcome, metrics
roadmap.md       ← Outcome-based deliverables (R1, R2, ...)
tasks/           ← One file per task (R1-task-01.md, ...)
architecture.md  ← System structure (created when needed)
decisions.md     ← ADRs (created when needed)
BLOCKERS.md      ← Failed tasks with error context
```
