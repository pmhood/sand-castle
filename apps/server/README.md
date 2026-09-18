# Sand Castle server

The single deployable backend service (docs/ARCHITECTURE.md §5 — "avoid microservices"), built
with Fastify on Node.js and TypeScript (§6). Right now it serves one route, `GET /health`. The
endpoint Phase 3 is actually about, `POST /api/test-runs` (§37), and everything behind it —
the Kubernetes runtime, the Job builder, persistence — are later issues in this phase.

```text
apps/server/
├── Makefile            checks: make lint | test | build | check
├── package.json        exact dependency pins; .npmrc keeps them exact
├── tsconfig.json       one config for the build, the editor and the linter
├── eslint.config.js    flat config, type-aware rules on
├── .nvmrc              the Node version CI and `nvm use` both read
├── src/
│   ├── app.ts          buildApp(): the Fastify instance and its routes
│   └── main.ts         the process entrypoint; the only thing that listens
└── test/
    └── health.test.ts  node:test suite, over a real socket
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
