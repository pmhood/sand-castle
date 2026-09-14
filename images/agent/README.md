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
    ├── runners/             one file per agent CLI: how it is invoked, and nothing else
    └── test/                bats-core suite
```

## What the bootstrap does

Validate the environment, create `/workspace/repo`, clone the repository and create the run
branch `sandcastle/<run-id>` (§25), fetch the issue into `/workspace/issue-context.json`, run
the agent, then log a result summary and exit with the agent's exit code.

The branch is neither pushed nor reported back: pushing, commenting and
`POST /internal/runs/:id/result` (§29/§30) are later phases, as is Engram (§41). The
`[ENGRAM]` log prefix is reserved and unused.

### Running the agent

`AGENT` selects a runner in `bootstrap/runners/`; an `AGENT` with no runner fails the run
rather than defaulting to Claude. The prompt is built once, from the issue context, and is the
same whichever CLI receives it: repository, issue number, title, body, labels, run ID and the
requirements list §26 spells out. Only the invocation differs (§27):

| `AGENT` | Invocation | Log prefix |
| --- | --- | --- |
| `claude` | `claude --print --permission-mode bypassPermissions`, prompt on stdin | `[CLAUDE]` |
| `codex` | `codex exec --dangerously-bypass-approvals-and-sandbox --color never -`, prompt on stdin | `[CODEX]` |

Both run with the checkout as their working directory, stream their output into the run log a
line at a time, and hand back their exit code unchanged. Permissions and sandboxing are
bypassed *inside* the CLI because the container is itself the sandbox (§11, §50); the prompt
travels on stdin, never in arguments the process table would expose.

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

The agent's own credential is not in that table: the bootstrap never reads it. It is passed
through to the CLI in the environment, which is the whole of §13 and §52 -- the CLI talks to
its provider, Sand Castle does not. See [agent credentials](#agent-credentials) for the shape
each CLI expects.

Every log line is prefixed with one of `[SANDCASTLE]`, `[GIT]`, `[ENGRAM]`, `[CLAUDE]`,
`[CODEX]`, `[TEST]`, `[GITHUB]` (§31; `[CODEX]` is the Codex twin of the `[CLAUDE]` prefix
that section names).

### Agent credentials

What each installed CLI accepts, for the `AgentCredentialProvider` that will inject it
(§15, §16, Phase 3). Verified against the versions pinned in the `Dockerfile` by running each
CLI in this image with a deliberately invalid credential and watching where it ended up.

| `AGENT` | Credential | How it is supplied |
| --- | --- | --- |
| `claude` | Subscription OAuth token (`claude setup-token`) | `CLAUDE_CODE_OAUTH_TOKEN` |
| `claude` | API key | `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) |
| `claude` | Prior `claude auth login` | `~/.claude/.credentials.json` (`CLAUDE_CONFIG_DIR` moves it) |
| `codex` | API key | `CODEX_API_KEY` |
| `codex` | ChatGPT access token | `CODEX_ACCESS_TOKEN` |
| `codex` | Prior `codex login` | `$CODEX_HOME/auth.json`, default `~/.codex/auth.json` |

Two differences matter to whoever injects these:

- The CLIs do not agree. Claude Code takes an OAuth token straight from the environment;
  Codex `0.154.0` does **not** read `OPENAI_API_KEY` (a run with only that variable set sent
  no credential at all) -- it wants `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, or an `auth.json`
  that `codex login --with-api-key` / `--with-access-token` writes from stdin. A mounted
  secret therefore needs `CODEX_HOME` pointed at its directory.
- A CLI can print a credential the provider rejects. With an invalid key, Codex relays
  OpenAI's `Incorrect API key provided: <key>` to its own stderr, and that reaches the run
  log. Nothing in the bootstrap logs a credential, but a rejected one can still surface this
  way; the fix belongs upstream of the log, in injecting a valid credential.

## Build and check

```sh
make -C images/agent check     # shellcheck, the bats suite, and docker build
```

`make test` installs a pinned `bats-core` into `images/agent/.bats` if `bats` is not already
on `PATH`. The suite needs no network and no credentials: it runs against a local git
repository and a local issue payload over `file://` URLs.

Run it under bash 5 before trusting a green result. macOS ships bash 3.2, which ignores
`errexit` for a bare `[[ ]]`, so a non-final `[[ ]]` assertion cannot fail a test there; CI
(ubuntu-24.04) and this image both enforce it:

```sh
docker run --rm -v "$PWD/images/agent:/agent" -w /agent \
  --entrypoint /agent/.bats/bin/bats sandcastle-agent:dev bootstrap/test
```

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

A full run against a public repository, with the issue payload served from a local fixture and
a fake CLI standing in for the agent, so that no credential is needed (the clone is anonymous;
the token is only ever offered when the server challenges). The run ends with the fake's exit
code, which is the whole path from environment to agent proved without one:

```sh
mkdir -p /tmp/fixture/repos/octocat/Hello-World/issues /tmp/fakebin
echo '{"number":1,"title":"Fixture issue","body":"body","labels":[]}' \
  > /tmp/fixture/repos/octocat/Hello-World/issues/1
printf '#!/bin/sh\necho "argv: $*"\ncat\nexit 42\n' > /tmp/fakebin/claude
chmod 755 /tmp/fakebin/claude
docker run --rm -v /tmp/fixture:/fixture:ro -v /tmp/fakebin:/fakebin:ro \
  -e PATH=/fakebin:/usr/local/bin:/usr/bin:/bin \
  -e SANDCASTLE_RUN_ID=run-local-001 \
  -e GITHUB_REPOSITORY=octocat/Hello-World \
  -e GITHUB_ISSUE_NUMBER=1 \
  -e AGENT=claude \
  -e GITHUB_TOKEN=not-a-real-token \
  -e GITHUB_API_URL=file:///fixture \
  sandcastle-agent:dev
```

Drop the `/fakebin` mount and the `PATH` override to run the real CLI, which then needs a real
credential in the environment ([agent credentials](#agent-credentials)).

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
- The agent's own credential is never read, copied or logged by the bootstrap either. The CLI
  inherits it from the environment and talks to its provider itself (§13, §52); the prompt
  travels on stdin, so nothing the run sends the agent appears in the process table. A CLI can
  still print a credential its provider rejected -- see
  [agent credentials](#agent-credentials). `agent.bats` asserts that the credential reaches
  the CLI and reaches nothing else.

## Versions pinned in this image

- Base image: `node:24-bookworm-slim`, pinned by tag and digest (see `Dockerfile`).
- `@anthropic-ai/claude-code` and `@openai/codex`: pinned exact versions (see `Dockerfile`
  `ARG`s). Bump these deliberately in a dedicated change, not as a side effect of another one.
