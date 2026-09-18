# Sand Castle server

The single deployable backend service (docs/ARCHITECTURE.md §5 — "avoid microservices"), built
with Fastify on Node.js and TypeScript (§6). It serves `GET /health` and `POST /api/test-runs`
(§37) — the endpoint Phase 3 is actually about: a request in, a Kubernetes Job out. Persistence,
run state, logs and watchers are Phase 4 (§38) and are not here yet; this endpoint is stateless.

```text
apps/server/
├── Makefile            checks: make lint | test | build | check
├── package.json        exact dependency pins; .npmrc keeps them exact
├── tsconfig.json       one config for the build, the editor and the linter
├── eslint.config.js    flat config, type-aware rules on
├── .nvmrc              the Node version CI and `nvm use` both read
├── src/
│   ├── app.ts          buildApp(): the Fastify instance and its routes
│   ├── main.ts         the process entrypoint; the only thing that listens
│   ├── api/
│   │   └── test-runs.ts    POST /api/test-runs: validation, and the status-code mapping (§37)
│   ├── sandbox/
│   │   └── runtime.ts  the SandboxRuntime boundary (§18)
│   └── kubernetes/
│       ├── job-builder.ts             buildAgentJob(): one run as a Kubernetes Job (§19, §20)
│       └── kubernetes-sandbox-runtime.ts  KubernetesSandboxRuntime: submits the Job (§18, §37)
└── test/
    ├── health.test.ts  node:test suite, over a real socket
    ├── api/
    │   └── test-runs.test.ts  the endpoint, over a real socket, against a fake SandboxRuntime
    └── kubernetes/
        ├── job-builder.test.ts             the Job builder, against the bash renderer it must match
        └── kubernetes-sandbox-runtime.test.ts  create(), against a fake Kubernetes client
```

## Running the checks

```sh
make -C apps/server lint     # eslint
make -C apps/server test     # node:test
make -C apps/server build    # tsc, into apps/server/dist
make -C apps/server check    # all three, in that order
```

Each target installs dependencies first if the lockfile is newer than `node_modules`, so all
four work from a clean checkout with nothing but Node on `PATH`. CI runs these same targets
(`.github/workflows/server.yml`).

The `npm` scripts underneath are `npm run lint`, `npm test` and `npm run build`; the Makefile
exists so the command shape matches `make -C images/agent lint` on the bash side.

## Running the server

```sh
make -C apps/server start                 # builds, then runs dist/src/main.js
PORT=8080 make -C apps/server start       # any port; 3000 is the default
```

It binds `0.0.0.0`, because the process is meant to run in a container where binding loopback
would make the port unreachable from outside the Pod.

```sh
curl -i http://127.0.0.1:3000/health
```

```text
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8

{"status":"ok"}
```

During development, Node runs the TypeScript sources directly — no build step:

```sh
node --watch apps/server/src/main.ts
```

## POST /api/test-runs

```sh
curl -i http://127.0.0.1:3000/api/test-runs \
    -H 'content-type: application/json' \
    -d '{"repository": "pmhood/level-zero", "issue": 142, "agent": "claude"}'
```

```text
HTTP/1.1 201 Created
content-type: application/json; charset=utf-8

{"sandboxId":"sandcastle-run-20260101-120000-abc123"}
```

Creates a Kubernetes Job for the given run and returns its ID. Nothing about the run is
persisted here — no database row, no way to look the run back up by this endpoint (that is Run
persistence, §38, Phase 4). This is `select credential, inject credential, launch, observe` (§52)
and nothing past it.

**This route's name is temporary.** §37 names it `POST /api/test-runs`; §33's Initial API has no
such route — it has `/api/runs` with `GET`, `GET /:id`, `.../logs`, `.../events` and
`POST /:id/stop`, none of which this endpoint can do yet, because those all need the Run
persistence §38 adds. `test-runs` says plainly that this is Phase 3 scaffolding rather than
promising verbs that do not exist. The full reasoning, and who is expected to rename it, is in
`src/api/test-runs.ts`'s file header — whichever issue implements §38 is the one that moves this
to `/api/runs`.

**Request body** — exactly these three fields, nothing else:

| field        | type   | constraint                                                            |
| ------------ | ------ | ---------------------------------------------------------------------- |
| `repository` | string | `owner/repo`; letters, digits, `.`, `_`, `-` only (job-builder.ts's own pattern) |
| `issue`      | number | a positive integer, no larger than 100,000,000                         |
| `agent`      | string | `"claude"` only — `create-secrets.sh` provisions no Codex credential   |

A body that is not an object, is missing a field, has the wrong type for one, fails one of the
constraints above, or carries any field beyond these three is rejected with `400` before
anything is rendered or reaches the cluster. An unexpected field is never echoed back — the
handler builds the runtime input field by field, not by forwarding the parsed body.

**Response status codes:**

| status | meaning                                                                          |
| ------ | --------------------------------------------------------------------------------- |
| `201`  | the Job was created; the body carries its `sandboxId`                             |
| `400`  | the request itself was malformed — see the table above                           |
| `502`  | the request was well-formed but the Kubernetes API refused to create the Job (RBAC denial, missing namespace, or any other rejection) |
| `503`  | the Kubernetes API could not be reached at all                                    |
| `500`  | anything else — a bug, not a classified cluster response                          |

A `502` or `503` body carries a fixed, generic message only. The namespace, the RBAC manifest to
check, and the Kubernetes API's own reason and message go to the server's own log
(`request.log.error`), not the HTTP response — that detail is for an operator, not a caller, and
this is also where §52/§57's "no credential in a response, request log, or error" is enforced:
nothing from the classified error is ever interpolated into what a client receives.

`src/app.ts`'s `buildApp` takes the `SandboxRuntime` this route calls as a plain required
argument — the test seam `SandboxRuntime` (§18) exists for. `src/main.ts` passes a real
`KubernetesSandboxRuntime`; `test/api/test-runs.test.ts` passes a fake that never touches a
cluster.

## The agent Job builder, the runtime that submits it, and the renderer that already existed

`src/kubernetes/job-builder.ts` turns a run — repository, issue, agent, run ID — into the
Kubernetes Job of §20. `src/kubernetes/kubernetes-sandbox-runtime.ts`'s `KubernetesSandboxRuntime`
submits exactly what it rendered (#53), and the endpoint above submits a request into both (#55).

`deploy/kubernetes/scripts/render-job.sh` renders the same manifest out of
`deploy/kubernetes/job.yaml`, and stays. Phase 2 runs on it, an operator on a cluster with no
server needs it, and this server needs an object for the Kubernetes API rather than YAML. Two
renderers of one manifest is what #26 was filed for, so they are pinned to each other instead of
trusted: `test/kubernetes/job-builder.test.ts` executes `render-job.sh`, parses its output, and
requires it to equal what the builder returns, field for field. Edit `job.yaml` without editing
the builder and `server-test` goes red. The full decision, including when the two converge, is in
the header of `src/kubernetes/job-builder.ts`; `deploy/kubernetes/README.md` says the same from
the other side.

No credential is involved on either side. Both produce `secretKeyRef` entries naming Secrets an
operator created; no token value is read, rendered, logged or written into a fixture (§14, §52,
§57).

## Why the toolchain looks like this

Every piece here is a decision the rest of the project inherits, so each one is the smallest
thing that does the job rather than the most capable.

- **npm, and no monorepo tool.** npm ships with Node, so CI and a developer machine need
  nothing installed beyond the runtime. There is exactly one package in this repository;
  workspaces, Turborepo and Nx all solve a problem — orchestrating builds across packages —
  that does not exist yet. §55 sketches `apps/web` and five `packages/*`, and the day two of
  them genuinely share code is the day to add a workspace root, with real requirements instead
  of guessed ones.

- **`node --test`, not Jest or Vitest.** Node 24 has a test runner and an assertion library in
  the box. A third-party runner would add a dependency tree and a config file to do what is
  already installed. `test/health.test.ts` binds a real socket on port 0 and makes a real
  `fetch`, rather than using Fastify's `inject` helper — with one route in the service, a test
  that never opens a port proves less than one that does.

- **One devDependency that is not a tool: `yaml`.** `test/kubernetes/job-builder.test.ts` has to
  read what `render-job.sh` actually printed, and that is YAML; Node has no parser for it and the
  repository's other YAML reader, `yq`, is a binary the server's CI jobs do not install. Comparing
  against a fixture written by hand instead would prove only that its author read the bash
  consistently, which is the failure #28 documents. It is a test-only dependency with no
  dependencies of its own, and it never ships in `dist/`.

- **`tsc`, not a bundler.** The server runs from `node_modules` on a Node runtime; there is
  nothing to bundle. `npm run build` emits plain ESM into `dist/`.

- **Node runs the `.ts` sources directly**, which is why the test command needs no build step.
  Node strips types; it does not compile them, so enums, namespaces and parameter properties
  would fail at run time. `tsconfig.json` sets `erasableSyntaxOnly`, which makes `tsc` reject
  exactly those, so the sources the build accepts are the sources Node can run. Relative
  imports therefore name the file that is really there (`./app.ts`) and `tsc` rewrites them to
  `.js` on the way into `dist/`.

  `dist/` mirrors the package, so the entrypoint is `dist/src/main.js`. That is also why
  `npm test` names its files with a glob: a bare `node --test` would discover the compiled
  copies under `dist/test/` and run every test twice.

- **ESLint with type-aware rules, and no formatter.** `tsc` already reports what it can see;
  the linter is here for what it cannot, and the rule that matters most for a Fastify service —
  `no-floating-promises` — needs type information. Formatting is a separate decision and not
  one this package has to make, any more than `shellcheck` formats the bash side.

## Dependency pinning

No dependency is a range. `package.json` names exact versions, and `.npmrc` sets
`save-exact=true` so a later `npm install` cannot reintroduce a `^`. `npm ci` installs exactly
what `package-lock.json` says and refuses to edit it, so CI and a developer machine resolve to
the same bytes.

Updates arrive as Dependabot pull requests (`.github/dependabot.yml`, ecosystem `npm`,
directory `/apps/server`), gated by the same three checks as any other change. That file also
carries the by-hand procedure for the exceptional case. The Node version is not a Dependabot
dependency: it lives in `.nvmrc` and is bumped deliberately, like the base image tag in
`images/agent/Dockerfile`.

## CI

`.github/workflows/server.yml` runs `lint`, `test` and `build` as three separate jobs, so a
failure names which of the three broke without reading a log. The `build` job additionally
starts what it compiled and curls `/health`: a `tsc` that emits a `dist/` nothing can start
would otherwise be a green check over a broken artifact.

Two details in that file are deliberate and worth not undoing:

- **`pull_request` has no `paths:` filter.** These are required status checks on the protected
  `main`, and GitHub treats a required check that never runs as still pending — so filtering
  them out on a change outside `apps/server` would block that pull request forever rather than
  pass it. The `push` trigger keeps its filter, because nothing downstream of it depends on
  these jobs. This is the same reasoning written at the top of
  `.github/workflows/agent-image.yml`.

- **The jobs are named `server-lint`, `server-test` and `server-build`.** A required status
  check is identified by its job name, not by the workflow it lives in; a job called `build`
  here would be indistinguishable from `agent-image.yml`'s `build` in the branch protection
  settings, and a required check the wrong workflow can satisfy is not a check.
