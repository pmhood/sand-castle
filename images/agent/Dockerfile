# Sand Castle agent sandbox image.
#
# One immutable image serving both agents (Claude Code CLI and Codex CLI). It contains no
# orchestration logic yet -- see /usr/local/bin/sandcastle-run, which is a placeholder until the
# bootstrap issue lands. See docs/ARCHITECTURE.md §11, §24, §50.

# Pin by tag *and* digest so this build is reproducible even if the tag is retagged upstream.
# node:24-bookworm-slim -- Node.js 24.x is the current LTS ("Krypton").
FROM node:24-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553

# Pin the CLI versions. Bump these deliberately, never track "latest".
ARG CLAUDE_CODE_VERSION=2.1.236
ARG CODEX_VERSION=0.154.0

# git, curl, jq, python3: required by the agents and by repository/tooling operations.
# bash and node/npm are already present in the base image.
# ca-certificates is required for npm/curl to make TLS requests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit \
        @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
        @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force

# Unprivileged user the container runs as by default (§50: non-root by default). The base
# image already ships a uid/gid 1000 "node" user with a home directory; reuse it rather than
# creating a second uid-1000 account.
RUN mkdir -p /workspace && chown node:node /workspace

COPY --chmod=755 sandcastle-run /usr/local/bin/sandcastle-run

# HOME is writable for agent/npm config and cache (~/.claude, ~/.codex, ~/.npm); everything
# else in the image is written only at build time, so the root filesystem can otherwise run
# read-only (§50). See images/agent/README.md for the writable paths a `--read-only` run needs.
ENV HOME=/home/node
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/local/bin/sandcastle-run"]
