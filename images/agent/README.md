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
(§15, §16, Phase 3), against the versions pinned in the `Dockerfile`. The last column says how
far each row was taken, because that is what decides whether Phase 3 can rely on it:

- **exercised** -- the CLI was run in this image with a deliberately invalid credential
  supplied this way, and the credential demonstrably reached the provider (the rejection names
  it) or the CLI demonstrably got as far as the provider;
- **documented** -- the CLI names it as an authentication source in its own help or binary,
  but no run has confirmed it end to end. Worth a check before Phase 3 depends on it.

| `AGENT` | Credential | How it is supplied | Confidence |
| --- | --- | --- | --- |
| `claude` | Subscription OAuth token (`claude setup-token`) | `CLAUDE_CODE_OAUTH_TOKEN` | documented |
| `claude` | API key | `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) | exercised |
| `claude` | Prior `claude auth login` | `~/.claude/.credentials.json` (`CLAUDE_CONFIG_DIR` moves it) | documented |
| `codex` | API key | `CODEX_API_KEY` (its own `login --with-api-key` help says `OPENAI_API_KEY`, which is not enough) | exercised |
| `codex` | ChatGPT access token | `CODEX_ACCESS_TOKEN` | documented |
| `codex` | Prior `codex login` | `$CODEX_HOME/auth.json`, default `~/.codex/auth.json` | exercised |

The two OAuth rows -- the ones the vertical slice actually wants (§13) -- are the documented
ones, because no OAuth credential was available here. Each is named by its CLI as an auth
source: Claude Code's error lists `ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
CLAUDE_CODE_OAUTH_TOKEN` as the accepted set, and `codex login --with-access-token` reads the
token that `CODEX_ACCESS_TOKEN` supplies. Proving them is the smoke harness's job.

Three differences matter to whoever injects these:

- **An empty value is not an absent one.** Every row above is supplied only when there is
  something to supply; a variable that is unset must not be materialised as `""`. The CLIs do
  not read `""` back as "absent": with `CLAUDE_CONFIG_DIR=""`, the Claude CLI resolves its
  config directory relative to the working directory and writes `backups/`, `projects/` and
  `sessions/` into the checkout the agent is working in, which a later phase would commit and
  push. (Codex `0.154.0` happens to fall back to `~/.codex` for an empty `CODEX_HOME`, but no
  CLI is owed that benefit of the doubt.) `scripts/smoke.sh` therefore builds its `docker run`
  arguments conditionally, adding `-e VAR` only for a variable that is set and non-empty;
  §16's `AgentCredentialProvider` has the same trap waiting in a Pod `env:` entry with an
  empty `value:`, and the same rule.

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

A green `make test` means the same thing on a developer Mac as it does in CI. macOS ships bash
3.2, which ignores `errexit` for a bare `[[ ]]`, so a `[[ ]]` assertion that is not the last
command of its test body cannot fail a test there. The suite therefore asserts only through
simple commands — `[ ... ]` and the helpers in `bootstrap/test/helpers.bash`, which return 1
explicitly — and `style.bats` fails if a bare `[[ ]]` assertion reappears. The image is still
the quickest way to run the same suite under bash 5:

```sh
docker run --rm -v "$PWD/images/agent:/agent" -w /agent \
  --entrypoint /agent/.bats/bin/bats sandcastle-agent:dev bootstrap/test
```

## Published image

CI (`.github/workflows/agent-image.yml`, job `publish`) builds and pushes a multi-arch image
to GHCR on every merge to `main` (docs/ARCHITECTURE.md §36) -- `linux/amd64` for the k3s
cluster's nodes, `linux/arm64` so local runs and this bats suite keep working unchanged on
Apple Silicon. `make -C images/agent publish` builds and pushes the same two platforms by
hand; it is an escape hatch for exceptional cases, not the normal path, because a
hand-published image can drift from the commit that supposedly produced it.

The package (`ghcr.io/pmhood/sandcastle-agent`) is meant to be public, so pulling it needs no
`imagePullSecret` and no `docker login` -- no such secret then exists to get wrong (§36):

```sh
docker pull ghcr.io/pmhood/sandcastle-agent:latest
docker run --rm --entrypoint bash ghcr.io/pmhood/sandcastle-agent:latest -c \
  'id -u; git --version; jq --version; node --version; python3 --version; claude --version; codex --version; command -v sandcastle-run'
```

**One-time maintainer setup.** A GHCR package does not exist until its first push, and
GitHub's REST API has no endpoint to change a package's visibility (confirmed while doing
this for #18 -- `PATCH /user/packages/container/sandcastle-agent` 404s; only the web UI can do
it). After the `publish` workflow's first run creates the package, a repo owner must make it
public by hand, once:

1. Open <https://github.com/users/pmhood/packages/container/package/sandcastle-agent>.
2. Click **Package settings**.
3. Under **Danger Zone**, click **Change visibility** -> **Public**, type the package name to
   confirm, then **I understand the consequences, change package visibility**.

Until that step is done the package stays private and the commands above need a
`docker login ghcr.io` first, with a token that has at least `read:packages`.

### Getting the current digest

Kubernetes Job manifests should reference the image by digest, not by the `latest` tag (§20).
There is no separate file in this repo recording it -- `latest` always points at the image the
most recent merge to `main` published, and `docker buildx imagetools inspect` (or the
equivalent `crane digest`) reads the digest straight from the registry, which cannot drift
from what is actually published the way a repo file copy could:

```sh
docker buildx imagetools inspect ghcr.io/pmhood/sandcastle-agent:latest
# or, for just the digest:
crane digest ghcr.io/pmhood/sandcastle-agent:latest
```

The `publish` job also writes the `imagetools inspect` output to its job summary, so the
digest a given merge produced is visible from that CI run without a local `docker` pull.

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
  this image. The build context excludes `.env`/`*.env` (`.dockerignore`), and the same
  Dockerfile produces the published image (`ghcr.io/pmhood/sandcastle-agent`), meant to be
  public (see [Published image](#published-image)); this was re-confirmed by scanning that
  image's layers directly (`docker save` + `tar`/`grep`), because the blast radius of being
  wrong is a different question once the artifact is public (#18).
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

## Running the Phase 1 smoke test

Phase 1's success criterion (§35) is that Claude CLI works non-interactively inside the
container with supplied OAuth credentials. The smoke harness at `scripts/smoke.sh` makes that
manual run trivial to perform and unambiguous to interpret.

```sh
make -C images/agent smoke
```

The harness accepts repository and issue number as arguments or environment variables, requires
credentials for the selected agent, and runs the image against that real target. If anything
fails, the operator can instantly see whether the failure was their credential, their token,
the network, the repository, or the CLI — not a failure in the bootstrap.

### Credentials

Set one of the required credentials for your chosen agent. The harness reads from environment
variables first; if they are not set, it looks for a git-ignored file at `images/.env.local`.

**Claude Code CLI (via `AGENT=claude`, the default):**

Set one of:
- `CLAUDE_CODE_OAUTH_TOKEN` — subscription OAuth token (`claude setup-token` prints one)
- `ANTHROPIC_API_KEY` — API key (less preferred; see [agent credentials](#agent-credentials))
- Prior login via `claude auth login` writes to `~/.claude/.credentials.json`

```sh
export CLAUDE_CODE_OAUTH_TOKEN="sk-..."
make -C images/agent smoke
```

or save to `images/.env.local`:

```sh
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-...' >images/.env.local
make -C images/agent smoke
```

**Codex CLI (via `AGENT=codex`):**

Set one of:
- `CODEX_API_KEY` — OpenAI API key
- `CODEX_ACCESS_TOKEN` — ChatGPT access token (`codex login --with-access-token` sets this)
- Prior login via `codex login` writes to `~/.codex/auth.json`

```sh
export CODEX_API_KEY="sk-..."
export AGENT=codex
make -C images/agent smoke

# Unset AGENT to return to Claude for subsequent runs
unset AGENT
```

**Note on prior login credentials:** The "prior login" options listed above (`~/.claude/.credentials.json`,
`~/.codex/auth.json`) are validated by the harness but will not authenticate through this Phase 1 test,
because the container does not mount your home directory into `/home/node`. Set an explicit credential
instead (OAuth token or API key).

### Target repository and issue

Provide a real public or private repository and issue number. The harness will clone the
repository, create a branch and read the issue (that is all Phase 1 does; pushing, commenting
and result callbacks are later phases).

```sh
export GITHUB_REPOSITORY=owner/repo
export GITHUB_ISSUE_NUMBER=123
make -C images/agent smoke
```

or pass them as arguments:

```sh
make -C images/agent smoke ARGS="owner/repo 123"
```

The issue number must be a valid integer. The harness does not modify anything in Phase 1,
so pointing at a non-existent issue is safe; you will see a GitHub API error.

### GitHub token

The harness also needs a GitHub token to clone the repository and read the issue.
Set `GITHUB_TOKEN` in the environment or in `images/.env.local`:

```sh
export GITHUB_TOKEN="ghp_..."
export CLAUDE_CODE_OAUTH_TOKEN="sk-..."
make -C images/agent smoke ARGS="owner/repo 123"
```

### Successful run

On success, the container output ends with:

```
[SANDCASTLE] Run smoke-<timestamp>-<random> completed
[SANDCASTLE]   repository=owner/repo issue=#123 agent=claude
[SANDCASTLE]   branch=sandcastle/smoke-<timestamp>-<random> exit_code=0
[SANDCASTLE]   branch not pushed and no result callback sent; both are later phases
```

This means:
- The container started successfully
- The CLI authenticated and read the repository and issue
- The harness proved the end-to-end OAuth path works
- No credentials were leaked (see [Security notes](#security-notes) for what the bootstrap
  asserts about this)

The branch created in the test repository is harmless: the operator can delete it manually,
or leave it for the next run (each run gets a new unique branch).

### Failure modes

**Missing credentials:**

```
[SMOKE] ERROR: Missing required credentials for agent 'claude'. Set one of: ...
```

Set a credential (above) and try again.

**Network or token issue:**

```
[GIT] fatal: could not read Username for 'https://github.com': ...
```

or:

```
[GITHUB] Could not fetch issue #123 (curl exit 22)
```

Check your `GITHUB_TOKEN` and that you have network access to github.com.

**Invalid OAuth token:**

The agent CLI will receive the token and attempt to authenticate. If the token is invalid or
expired, you will see an error from the CLI:

```
[CLAUDE] Error: ...
```

Verify your credential is correct and unexpired, then try again.

### Credential file security

The `images/.env.local` file is git-ignored and never committed. You are responsible for:
- Keeping it private and never committing it
- Removing it or rotating your credentials before sharing your machine
- Being aware that `$HOME` is writable in the container, so a stale dotfile can interfere with
  the run (see [Security notes](#security-notes) for what protections the bootstrap has)

## Versions pinned in this image

- Base image: `node:24-bookworm-slim`, pinned by tag and digest (see `Dockerfile`).
- `@anthropic-ai/claude-code` and `@openai/codex`: pinned exact versions (see `Dockerfile`
  `ARG`s). Bump these deliberately in a dedicated change, not as a side effect of another one.
