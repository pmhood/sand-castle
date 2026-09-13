# Sand Castle agent sandbox image

One immutable image that runs both agents (Claude Code CLI and Codex CLI). See
`docs/ARCHITECTURE.md` §11 (agent sandbox container), §24 (workspace), §50 (security
boundaries).

`ENTRYPOINT` is `/usr/local/bin/sandcastle-run`, the bootstrap that owns run orchestration
inside the container (§12) so that orchestration never becomes a giant Kubernetes command.

```text
images/agent/
├── Dockerfile
├── Makefile            checks: make lint | test | build | check
└── bootstrap/
    ├── sandcastle-run       the bootstrap itself
    ├── sandcastle-askpass   GIT_ASKPASS helper; keeps the token out of URLs and logs
    └── test/                bats-core suite
```

## What the bootstrap does

Validate the environment, create `/workspace/repo`, clone the repository and create the run
branch `sandcastle/<run-id>` (§25), fetch the issue into `/workspace/issue-context.json`, run
the agent, then log a result summary and exit with the agent's exit code.

Invoking the agent is still a stub, and the branch is neither pushed nor reported back:
pushing, commenting and `POST /internal/runs/:id/result` (§29/§30) are later phases, as is
Engram (§41). The `[ENGRAM]` log prefix is reserved and unused.

### Environment

| Variable | Required | Meaning |
| --- | --- | --- |
| `SANDCASTLE_RUN_ID` | yes | Unique run identifier; also the run branch suffix |
| `GITHUB_REPOSITORY` | yes | `owner/repo` the run works in |
| `GITHUB_ISSUE_NUMBER` | yes | Issue the run is about |
| `AGENT` | yes | `claude` or `codex` (§27) |
| `GITHUB_TOKEN` | yes | Scoped token used to clone and to read the issue (§17) |
| `GITHUB_SERVER_URL` | no | git host, default `https://github.com` |
| `GITHUB_API_URL` | no | GitHub API root, default `https://api.github.com` |
| `SANDCASTLE_WORKSPACE` | no | Workspace root, default `/workspace` (§24) |

Every log line is prefixed with one of `[SANDCASTLE]`, `[GIT]`, `[ENGRAM]`, `[CLAUDE]`,
`[TEST]`, `[GITHUB]` (§31).

## Build and check

```sh
make -C images/agent check     # shellcheck, the bats suite, and docker build
```

`make test` installs a pinned `bats-core` into `images/agent/.bats` if `bats` is not already
on `PATH`. The suite needs no network and no credentials: it runs against a local git
repository and a local issue payload over `file://` URLs.

## Verify the image by hand

```sh
docker build -t sandcastle-agent:dev images/agent
```

Every required tool resolves on `PATH`, and the container is uid 1000, not root:

```sh
docker run --rm --entrypoint bash sandcastle-agent:dev -c \
  'id -u; git --version; jq --version; node --version; python3 --version; claude --version; codex --version; command -v sandcastle-run'
```

A run with no environment fails fast, naming the variables it needs and exiting non-zero:

```sh
docker run --rm sandcastle-agent:dev
```

A full run against a public repository, with the issue payload served from a local fixture so
that no credential is needed (the clone is anonymous; the token is only ever offered when the
server challenges):

```sh
mkdir -p /tmp/fixture/repos/octocat/Hello-World/issues
echo '{"number":1,"title":"Fixture issue","body":"body","labels":[]}' \
  > /tmp/fixture/repos/octocat/Hello-World/issues/1
docker run --rm -v /tmp/fixture:/fixture:ro \
  -e SANDCASTLE_RUN_ID=run-local-001 \
  -e GITHUB_REPOSITORY=octocat/Hello-World \
  -e GITHUB_ISSUE_NUMBER=1 \
  -e AGENT=claude \
  -e GITHUB_TOKEN=not-a-real-token \
  -e GITHUB_API_URL=file:///fixture \
  sandcastle-agent:dev
```

## Security notes

- Runs as uid 1000 by default; nothing in the image requires root at run time.
- Everything under the image's filesystem is written at build time only, with one exception:
  `$HOME` (`/home/node` -- the uid/gid 1000 user the base `node` image ships with, reused here
  instead of creating a second uid-1000 account) is left writable, because the agent CLIs and
  npm write config and cache there (for example `~/.claude`, `~/.codex`, `~/.npm`). A
  `docker run --read-only` deployment should mount `/home/node` (and `/tmp`) as writable
  `tmpfs`/volumes; `/workspace` is already expected to be a writable, per-run volume (§24).
- No credential, token, or `.env` file is baked into any layer; none was used to build or test
  this image.
- `GITHUB_TOKEN` never reaches a log line, a URL, the process table, or the disk (§14):
  - git receives it through `GIT_ASKPASS`, so it is absent from the remote URL, from
    `.git/config` and from git's own error output when a clone fails;
  - the GitHub API receives it as a header read from stdin (`curl --config -`), never as a
    command-line argument, which the process table would expose for the length of the request;
  - `$HOME` is writable here by design, so config a run inherits is treated as hostile:
    `curl --disable` ignores a `~/.curlrc` that asks for `verbose`, `GIT_TRACE_REDACT=1`
    keeps the header out of a trace the environment turns on, and an emptied
    `credential.helper` stops a planted `~/.gitconfig` persisting the token;
  - both scripts disable shell tracing, which would otherwise expand the token into it;
  - output relayed from git, curl and jq is re-emitted through the prefixed logger, so no
    failure path prints an unprefixed line either (§31).

  `credentials.bats` and `askpass.bats` assert all of this on the success path and on every
  failure path, including a real credential challenge from a local server.

## Versions pinned in this image

- Base image: `node:24-bookworm-slim`, pinned by tag and digest (see `Dockerfile`).
- `@anthropic-ai/claude-code` and `@openai/codex`: pinned exact versions (see `Dockerfile`
  `ARG`s). Bump these deliberately in a dedicated change, not as a side effect of another one.
