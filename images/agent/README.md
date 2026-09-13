# Sand Castle agent sandbox image

One immutable image that runs both agents (Claude Code CLI and Codex CLI). See
`docs/ARCHITECTURE.md` §11 (agent sandbox container), §24 (workspace), §50 (security
boundaries).

This image contains no orchestration logic. `ENTRYPOINT` is `/usr/local/bin/sandcastle-run`,
which today only logs `[SANDCASTLE] bootstrap not yet implemented` and exits `0`. The real
bootstrap (workspace prep, repository checkout, agent invocation, result reporting) is a
follow-up issue.

## Build

```sh
docker build -t sandcastle-agent:dev images/agent
```

## Verify

Runs as the unprivileged `node` user (uid 1000), not root, and the placeholder entrypoint
exits `0`:

```sh
docker run --rm sandcastle-agent:dev
```

Confirm every required tool resolves on `PATH` and reports a version, overriding the
entrypoint:

```sh
docker run --rm --entrypoint bash sandcastle-agent:dev -c \
  'id -u; git --version; jq --version; node --version; python3 --version; claude --version; codex --version'
```

## Security notes

- Runs as uid 1000 by default; nothing in the image requires root at run time.
- Everything under the image's filesystem is written at build time only, with one exception:
  `$HOME` (`/home/node` -- the uid/gid 1000 user the base `node` image ships with, reused here
  instead of creating a second uid-1000 account) is left writable, because the agent CLIs and
  npm write config and cache there (for example `~/.claude`, `~/.codex`, `~/.npm`). A
  `docker run --read-only` deployment should mount `/home/node` (and `/tmp`) as writable
  `tmpfs`/volumes; `/workspace` is already expected to be a writable, per-run volume (§24).
- No credential, token, or `.env` file is baked into any layer; the placeholder entrypoint
  needs none, and none was used to build or test this image.

## Versions pinned in this image

- Base image: `node:24-bookworm-slim`, pinned by tag and digest (see `Dockerfile`).
- `@anthropic-ai/claude-code` and `@openai/codex`: pinned exact versions (see `Dockerfile`
  `ARG`s). Bump these deliberately in a dedicated change, not as a side effect of another one.
