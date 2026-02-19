FROM node:24-bookworm-slim

ARG OPENCLAW_VERSION=2026.2.17
ARG GIT_COMMIT_SHA=dev

ENV NODE_ENV=production

# OpenClaw conventions (authoritative env var names per OpenClaw docs)
ENV HOME=/home/openclaw
ENV OPENCLAW_STATE_DIR=/home/openclaw/.openclaw
ENV OPENCLAW_CONFIG_PATH=/run/openclaw/openclaw.json

# OS deps:
# - jq/envsubst: config generation
# - python venv: awscli for Spaces/RustFS sync
# - procps: healthcheck (pgrep)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    gettext-base \
    git \
    jq \
    procps \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# AWS CLI (installed in a venv to keep system site-packages clean)
RUN python3 -m venv /opt/awscli && \
    /opt/awscli/bin/pip install --no-cache-dir awscli && \
    ln -s /opt/awscli/bin/aws /usr/local/bin/aws

# Non-root user (required by DigitalOcean App Platform)
RUN useradd --uid 10001 --create-home --home-dir /home/openclaw --shell /bin/bash openclaw

# Copy scripts + templates (as root, then lock down perms)
RUN mkdir -p /etc/openclaw /usr/local/bin /run/openclaw && \
    chown -R openclaw:openclaw /run/openclaw && \
    chmod 700 /run/openclaw

RUN echo "${OPENCLAW_VERSION}" > /etc/openclaw/VERSION && \
    echo "${GIT_COMMIT_SHA}" > /etc/openclaw/GIT_COMMIT_SHA

COPY config/openclaw.base.json /etc/openclaw/openclaw.base.json
COPY scripts/entrypoint.sh /usr/local/bin/openclaw-entrypoint
COPY scripts/setup-providers.sh /usr/local/bin/openclaw-setup-providers
COPY scripts/setup-channels.sh /usr/local/bin/openclaw-setup-channels
COPY scripts/restore.sh /usr/local/bin/openclaw-restore
COPY scripts/backup.sh /usr/local/bin/openclaw-backup
COPY scripts/healthcheck.sh /usr/local/bin/openclaw-healthcheck

RUN chmod 0555 /usr/local/bin/openclaw-entrypoint \
               /usr/local/bin/openclaw-setup-providers \
               /usr/local/bin/openclaw-setup-channels \
               /usr/local/bin/openclaw-restore \
               /usr/local/bin/openclaw-backup \
               /usr/local/bin/openclaw-healthcheck && \
    chmod 0444 /etc/openclaw/openclaw.base.json && \
    chown -R openclaw:openclaw /etc/openclaw

USER openclaw
WORKDIR /home/openclaw

# Configure npm for user-local global installs
ENV NPM_CONFIG_PREFIX=/home/openclaw/.npm-global
ENV PATH=/home/openclaw/.npm-global/bin:$PATH
ENV NODE_PATH=/home/openclaw/.npm-global/lib/node_modules

# Install OpenClaw (pinned)
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" && \
    npm cache clean --force && \
    rm -rf /home/openclaw/.npm

# Ensure required directories exist and are owned by openclaw
RUN mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory" \
             "${OPENCLAW_STATE_DIR}/credentials" \
             "${OPENCLAW_STATE_DIR}/agents" \
             "${OPENCLAW_STATE_DIR}/cache" && \
    chmod 700 "${OPENCLAW_STATE_DIR}" && \
    chmod 700 "${OPENCLAW_STATE_DIR}/credentials"

EXPOSE 18789

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD /usr/local/bin/openclaw-healthcheck

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint"]
