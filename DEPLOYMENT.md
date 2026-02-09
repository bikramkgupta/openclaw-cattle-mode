# Deployment Rules

This document defines the fixed deployment process for OpenClaw Cattle Mode.
Follow these rules exactly — do not improvise or deviate.

---

## Environment Files

There are four env files. Each has a specific purpose. Do not mix them up.

| File | Purpose | Gitignored | Used by |
|---|---|---|---|
| `.env.docker` | Local Docker Compose secrets + config | Yes | `docker compose --env-file .env.docker` |
| `.env.docker.example` | Template for `.env.docker` | No | Developers copy this to `.env.docker` |
| `.env.remote` | App Platform secrets + config | Yes | `scripts/deploy.sh` |
| `.env.remote.example` | Template for `.env.remote` | No | Developers copy this to `.env.remote` |

### Rules

1. **Never commit `.env.docker` or `.env.remote`** — they contain real secrets.
2. **Never hardcode secrets in `app.yaml`** — it uses `${VAR}` placeholders.
3. **Never use `.env.docker` for App Platform** — it has local-only values (RustFS, localhost endpoints).
4. **Never use `.env.remote` for Docker Compose** — it has production values (DO Spaces, real tokens).
5. **Keep `.env.docker.example` and `.env.remote.example` in sync** with any new env vars added to `app.yaml` or `docker-compose.yml`.

### Creating env files from scratch

```bash
# Local development
cp .env.docker.example .env.docker
# Fill in: TELEGRAM_BOT_TOKEN, GRADIENT_API_KEY, OPENCLAW_GATEWAY_TOKEN

# App Platform
cp .env.remote.example .env.remote
# Fill in: TELEGRAM_BOT_TOKEN, GRADIENT_API_KEY, OPENCLAW_GATEWAY_TOKEN,
#          SPACES_ACCESS_KEY_ID, SPACES_SECRET_ACCESS_KEY
```

### Generating secrets

```bash
# Gateway token (used in both .env.docker and .env.remote)
openssl rand -hex 32

# Spaces access key (only for .env.remote)
doctl spaces keys create "my-key-name" \
  --grants "bucket=<bucket>;permission=readwrite" \
  --output json
# Secret key is shown ONLY at creation time — save it immediately.
```

---

## Deploy Method 1: Local Docker Compose

**Env file:** `.env.docker`

```bash
docker compose --env-file .env.docker up -d
```

Docker Compose reads `.env.docker` and starts all services locally (agent + RustFS).

### Rebuild after image changes

```bash
docker compose --env-file .env.docker build --no-cache openclaw-agent
docker compose --env-file .env.docker up -d
```

### Logs and health

```bash
docker compose --env-file .env.docker logs -f openclaw-agent
docker compose --env-file .env.docker exec openclaw-agent /usr/local/bin/openclaw-healthcheck
```

---

## Deploy Method 2: App Platform via deploy.sh

**Env file:** `.env.remote`

```bash
bash scripts/deploy.sh
```

### What deploy.sh does (in order)

1. Reads `.env.remote`
2. Runs `envsubst` on `app.yaml` → writes `.app-spec-rendered.yaml` (temp file)
3. Finds or creates the app via `doctl apps`
4. Runs `doctl apps update <app-id> --spec .app-spec-rendered.yaml`
5. **Deletes `.app-spec-rendered.yaml` immediately** (secrets must not persist on disk)
6. Triggers `doctl apps create-deployment`
7. Waits for deployment to reach ACTIVE or ERROR

### Dry run (preview rendered spec without deploying)

```bash
bash scripts/deploy.sh --dry-run
```

### Prerequisites

- `doctl` installed and authenticated (`doctl auth init`)
- `envsubst` installed (`brew install gettext` on macOS)
- `.env.remote` populated with all values

---

## Deploy Method 3: GitHub Actions (CI/CD)

**Secrets stored in:** GitHub repo Settings → Secrets → Actions

### Image build (current)

The GHCR workflow builds and pushes the container image:

```bash
# Trigger manually
gh workflow run ghcr-build-push.yml -f openclaw_version=2026.2.6
```

This pushes to `ghcr.io/bikramkgupta/openclaw-agent` with tags: `latest`, `<version>`, `<sha>`.

### Integration workflow (container test + optional deploy)

The **Integration** workflow (`.github/workflows/integration.yml`) runs on push/PR and optionally on manual trigger:

1. **deploy-spec** — Renders `app.yaml` with envsubst and checks for unsubstituted variables (no secrets needed).
2. **container-test** — Builds and runs the stack with Docker Compose. Creates `.env.docker` from GitHub Secrets:
   - **Required:** `AGENT_ID`, `OPENCLAW_GATEWAY_TOKEN` (container will not boot without these).
   - **Optional:** `TELEGRAM_BOT_TOKEN`, `GRADIENT_API_KEY`. If both are set, the job runs **full E2E** (`test-backup.sh`: backup/restore against local RustFS). Otherwise it runs **smoke only** (`smoke-boot.sh`: container boots and health check passes).
3. **deploy** — Runs only when you trigger the workflow manually and check **Run deploy to App Platform**. Requires `DIGITALOCEAN_TOKEN` and every variable from `.env.remote` as GitHub Secrets (same list as below). Uses `doctl` to update the app spec and create a deployment, then waits for ACTIVE.

**Secrets for container-test (minimum for smoke):**

| Secret | Required for smoke | Required for full E2E |
|--------|--------------------|------------------------|
| `AGENT_ID` | Yes | Yes |
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Yes |
| `TELEGRAM_BOT_TOKEN` | No | Yes |
| `GRADIENT_API_KEY` | No | Yes |

**Secrets for deploy job:** `DIGITALOCEAN_TOKEN` plus all `.env.remote` vars (e.g. `AGENT_ID`, `AGENT_NAME`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWFROM`, `GRADIENT_API_KEY`, `AGENT_DEFAULT_MODEL`, `NODE_OPTIONS`, `OPENCLAW_GATEWAY_TOKEN`, `SPACES_BUCKET`, `SPACES_REGION`, `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`, and optionally `IMAGE_TAG`).

---

## app.yaml — Template Format

`app.yaml` is a **template**, not a directly deployable spec. It contains `${VAR}` placeholders:

```yaml
envs:
  - key: TELEGRAM_BOT_TOKEN
    scope: RUN_TIME
    value: "${TELEGRAM_BOT_TOKEN}"
```

**Never deploy `app.yaml` directly with `doctl apps update --spec app.yaml`.**
Always use `scripts/deploy.sh` which substitutes values from `.env.remote`.

---

## GHCR Image Configuration

App Platform pulls from GHCR using:

```yaml
image:
  registry_type: GHCR
  registry: ghcr.io
  repository: bikramkgupta/openclaw-agent
  tag: ${IMAGE_TAG}
```

- The tag is set by `IMAGE_TAG` in `.env.remote` (e.g. `2026.2.6`). Use a pinned tag so deploys don't pull `latest` unexpectedly.
- `registry_type: GHCR` is required — it handles GHCR's token-exchange auth.
- `DOCKER_HUB` does **not** work for GHCR images.
- For public GHCR images, no `registry_credentials` needed.
- For private GHCR images, add: `registry_credentials: "<username>:<PAT>"`

---

## Adding a New Environment Variable

When adding a new env var, update **all** of these:

1. `app.yaml` — add `${NEW_VAR}` placeholder in the envs section
2. `.env.remote.example` — add with blank or default value
3. `.env.remote` — add with real value
4. `.env.docker.example` — add with blank or default value (if used locally)
5. `.env.docker` — add with real value (if used locally)
6. `docker-compose.yml` — add to environment section (if used locally)

---

## Quick Reference

| Task | Command |
|---|---|
| Start locally | `docker compose --env-file .env.docker up -d` |
| Deploy to App Platform | `bash scripts/deploy.sh` |
| Preview deploy spec | `bash scripts/deploy.sh --dry-run` |
| Build image (GHCR) | `gh workflow run ghcr-build-push.yml` |
| Build image (DOCR) | `gh workflow run build-push.yml` |
| Check deploy logs | `doctl apps logs <app-id> --type deploy` |
| Check runtime logs | `doctl apps logs <app-id> --type run` |
| Test deploy spec (no Docker) | `bash scripts/test-deploy-spec.sh` |
| Test smoke boot | `bash scripts/smoke-boot.sh` |
| Test backup/restore | `bash scripts/test-backup.sh` |
| Test version compat | `bash scripts/test-versions.sh` |
