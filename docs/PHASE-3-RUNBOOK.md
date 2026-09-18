# Phase 3 runbook — an HTTP request to an agent run

Phase 3 (ARCHITECTURE.md §37) is done when this chain works end to end:

```text
HTTP request
    ↓
Sand Castle
    ↓
Kubernetes Job
    ↓
Claude
```

This document is how an operator makes that happen, what each step should look like, what it
looks like when it does not, and — in "What was observed" — what actually happened the one time
it was run for real. A unit test proving the server calls a fake client demonstrates none of
that, which is why Phase 2 left `deploy/kubernetes/README.md` and scripts rather than only a CI
job (§36), and why Phase 3 leaves this.

**Why it lives in `docs/` rather than in a component's README.** The procedure spans two
components, and each existing README is scoped to one and says so in its first paragraph:
`apps/server/README.md` is the server's build, routes and toolchain; `deploy/kubernetes/README.md`
is the manifests and the operator scripts for a cluster with no server on it. A run that starts
with `curl` on a laptop and ends with a Pod on `red` belongs to neither, and putting it in one
would make it invisible from the other. It sits beside `ARCHITECTURE.md`, whose §37 it proves,
so `ls docs/` from the repository root finds it; both READMEs link here.

## What this proves

Only the middle of §42's First Acceptance Test. §42's chain starts at a GitHub webhook and ends
with a pushed branch and an issue comment:

| §42 step | Phase | Here? |
| --- | --- | --- |
| Webhook received | 5 (§39) | no |
| Run created | 4 (§38) | no — nothing is persisted; see "What Phase 3 does not give you" |
| Job created | **3 (§37)** | **yes** |
| Claude starts | **3** | **yes** |
| Repo cloned | 1/2 (§35, §36) | yes, and exercised again here |
| File created | 1 | yes |
| Commit created | 1 | yes |
| Branch pushed | 6 (§40) | no — the run says so itself and stops |
| Issue commented | 6 | no |
| Run completed | 4 | no — no run states exist to move through |
| Job exits | 2 | yes |

So a green run here is not §42 passing. It is §42's middle four rows, reached from an HTTP
request instead of from `launch-run.sh`, which is exactly what §37 asks for and no more.

## Prerequisites

Everything below is once per cluster except the last two rows.

| What | How | Why |
| --- | --- | --- |
| `kubectl`, and a reachable cluster | `kubectl get nodes` | the server talks to the API server through your kubeconfig — see "Which identity the server uses" |
| The namespace | `kubectl apply -f deploy/kubernetes/namespace.yaml` | §21; the Job carries this namespace and nothing creates it |
| The run's identity | `kubectl apply -f deploy/kubernetes/serviceaccount.yaml` | §50; the Pod will not start without it |
| The server's identity and RBAC | `kubectl apply -f deploy/kubernetes/server-serviceaccount.yaml`, `server-role.yaml`, `server-rolebinding.yaml` | §22, #54; `deploy/kubernetes/README.md`, "The server's identity" |
| The two credential Secrets | `./deploy/kubernetes/scripts/create-secrets.sh` | §14, §15 — see "Credentials" below |
| Nodes measured | `./deploy/kubernetes/scripts/probe-nodes.sh` | #30; **until this has run, nothing schedules at all** |
| Node 24 and npm | `nvm use` in `apps/server`, or any Node matching `apps/server/.nvmrc` | the server is what serves the request |
| A repository and issue the GitHub token can read | — | the run clones it and reads the issue |

### Credentials

Two, and Sand Castle knows a Secret *name*, a *key* and a *credential type* — never a value
(§14, §15, §52). `create-secrets.sh` already solves installing them without putting a value in
`argv`, where any user on the machine can read it out of the process table; do not reinvent it
and do not reach for `kubectl create secret --from-literal`.

```sh
export GITHUB_TOKEN=...              # scoped to the one repository the run works in
export CLAUDE_CODE_OAUTH_TOKEN=...   # from `claude setup-token` — the token, not the banner it prints
./deploy/kubernetes/scripts/create-secrets.sh
```

`deploy/kubernetes/README.md`'s "Credentials" section is the authority on both: which Secret
holds which, what each is for, how to rotate them, and why the value never becomes an argument.

To confirm they are installed **without printing anything**:

```sh
./deploy/kubernetes/scripts/create-secrets.sh --verify
```

```text
[SECRETS] sandcastle-github-token: key 'token' present, 40 bytes (value not shown)
[SECRETS] sandcastle-claude-oauth: key 'token' present, 108 bytes (value not shown)
[SECRETS] Both Secrets are present with the keys job.yaml expects
```

**Never run `kubectl get secret -o yaml`, `-o json`, `-o jsonpath='{.data...}'` or
`-o custom-columns=...:.data`.** All four print the base64-encoded *value*, and base64 is not
encryption: a credential in your terminal is a credential in your scrollback (§57). To confirm a
Secret merely exists, `kubectl -n sandcastle-agents get secrets` with no output format lists
name, type and key count and nothing else. This is not a hypothetical — it is how a live
credential was exposed on this project once.

## The procedure

### 1. Confirm the cluster is ready

```sh
kubectl -n sandcastle-agents get secrets                 # names and key counts only
kubectl -n sandcastle-agents get serviceaccounts
kubectl -n sandcastle-agents get role,rolebinding
./deploy/kubernetes/scripts/create-secrets.sh --verify
./deploy/kubernetes/scripts/probe-nodes.sh --show        # changes nothing
```

`probe-nodes.sh --show` must report at least one node `true`, measured against the same digest
`deploy/kubernetes/job.yaml` pins. The server does **not** check this before submitting — see
"The server has no preflight" — so checking it is yours to do here.

The server's Role can be confirmed without a run:

```sh
kubectl auth can-i create jobs --as=system:serviceaccount:sandcastle-agents:sandcastle-server -n sandcastle-agents   # yes
kubectl auth can-i create jobs --as=system:serviceaccount:sandcastle-agents:sandcastle-server -n default             # no
```

### 2. Start the server

```sh
make -C apps/server start                 # builds, then runs dist/src/main.js on port 3000
PORT=3100 make -C apps/server start       # any port, if 3000 is taken
curl -s http://127.0.0.1:3100/health      # {"status":"ok"}
```

It binds `0.0.0.0`. A port already in use is a clean failure, not a hang — the process logs
`EADDRINUSE` and exits 1.

### 3. Make the request

```sh
curl -i http://127.0.0.1:3100/api/test-runs \
    -H 'content-type: application/json' \
    -d '{"repository": "<owner>/<repo>", "issue": <n>, "agent": "claude"}'
```

```text
HTTP/1.1 201 Created
content-type: application/json; charset=utf-8

{"sandboxId":"sandcastle-run-<UTC timestamp>-<6 hex>"}
```

The `sandboxId` is the Job's name. Write it down: it is the only handle you get, because nothing
is persisted (§38 is Phase 4's). If you lose it, `kubectl -n sandcastle-agents get jobs` is how
you find the run again.

`apps/server/README.md`'s "POST /api/test-runs" has the request and response contracts in full.
The short version: exactly three fields and no others, `agent` must be `claude` (no Codex
credential exists — `deploy/kubernetes/README.md`, "Running Codex instead of Claude"), and a
malformed request is a 400 at the door.

### 4. Watch it on the cluster

`kubectl` is the only view of progress there is.

```sh
RUN=<the sandboxId from step 3>
kubectl -n sandcastle-agents get job "$RUN"
kubectl -n sandcastle-agents get pods -l "sandcastle.run=${RUN#sandcastle-}" -o wide
kubectl -n sandcastle-agents logs -f -l "sandcastle.run=${RUN#sandcastle-}" --tail=-1
```

The label is the run ID without the `sandcastle-` prefix the Job's name carries — `job.yaml`
sets `sandcastle.run: "${RUN_ID}"` on both the Job and the Pod template.

A successful run's logs carry the §31 stage prefixes the bootstrap gives them and end with:

```text
[SANDCASTLE] Run <run-id> completed
[SANDCASTLE]   repository=<owner>/<repo> issue=#<n> agent=claude
[SANDCASTLE]   branch=sandcastle/<run-id> exit_code=0
[SANDCASTLE]   branch not pushed and no result callback sent; both are later phases
```

That last line is Phase 3 being honest about its own edges: the agent changed files and committed
on a branch inside the Pod, and that branch dies with the Pod. Pushing it is Phase 6 (§40).

`logs -f` ends when the container does. If you attach after the Pod has terminated the logs are
still there — until the Job is deleted, which is the next step.

### 5. Clean up

See "Cleanup" below. The short version, once you have read what you need from the logs:

```sh
kubectl -n sandcastle-agents delete job "$RUN"    # deletes its Pod too, and the only copy of its logs
```

## What was observed

Run for real against the k3s cluster on **2026-09-18**, from commit `54a1677` plus this
document. Observed, not asserted — every line below is something a command printed.

| Step | What was observed |
| --- | --- |
| Prerequisites | Namespace `sandcastle-agents` active. Both Secrets present, one key each (`--verify`: 40 and 108 bytes, values not shown). `sandcastle-agent` and `sandcastle-server` ServiceAccounts, and the `sandcastle-server` Role and RoleBinding, all present. `can-i create jobs` as `sandcastle-server`: `yes` in `sandcastle-agents`, `no` in `default`, `no` to `'*' '*'` cluster-wide. |
| Nodes | `probe-nodes.sh --show`: `red` `true`, `nova` `false`, both measured against `sha256:de6e6b92…` — the digest `job.yaml` pins today. |
| Server | `PORT=3100 make -C apps/server start`. `GET /health` → `200 {"status":"ok"}`. (Port 3000 was taken by an unrelated process on the machine; the server logged `EADDRINUSE` and exited 1, which is how that failure reads.) |
| HTTP request | `POST /api/test-runs` with `{"repository":"pmhood/alpine","issue":1,"agent":"claude"}` at `20:12:40Z` → **`201 Created`**, `{"sandboxId":"sandcastle-run-20260918-201240-4b9f4c"}`, in 36 ms. |
| Kubernetes Job | The Job existed 3 s later: `sandcastle-run-20260918-201240-4b9f4c`, `startTime 20:12:40Z`. |
| Pod | `sandcastle-run-20260918-201240-4b9f4c-dd64k`, `Running` on node **`red`**, image `ghcr.io/pmhood/sandcastle-agent@sha256:de6e6b92…` (the pinned digest), `runAsUser: 1000`. |
| **Claude** | The Pod's logs: environment validated, workspace ready, `pmhood/alpine` cloned, branch `sandcastle/run-20260918-201240-4b9f4c` created, issue #1 read (`Add a README.md`), issue context written, **`[CLAUDE] Starting Claude Code CLI in /workspace/repo`**, and then the agent's own summary — it found the repository empty, wrote a minimal `README.md` and committed it as the root commit. **`[CLAUDE] Claude Code CLI exited with status 0`**. |
| Job completion | `Complete`, `1/1`, duration **22 s**, `completionTime 20:13:02Z`, container `Completed` exit `0`. |
| Cleanup | `kubectl delete job sandcastle-run-20260918-201240-4b9f4c` at `20:13:50Z`; the Job and its Pod both gone. |

**The milestone reached is the strongest one on offer: the agent completed its work.** Not merely
a Job created, not merely a Pod scheduled, not merely the CLI starting — Claude Code authenticated
with the OAuth Secret, read the issue, changed the repository and exited 0, and the chain from
`curl` to that took 22 seconds. §37's success criterion is met.

Two rejections were exercised in the same session, since a runbook that only shows the happy path
is the one #28 and #41 were filed about:

```text
{"repository":"pmhood/alpine","issue":1,"agent":"codex"}          → 400  body/agent must be equal to one of the allowed values
{"repository":"pmhood/alpine","issue":1,"agent":"claude","token":"x"} → 400  body must NOT have additional properties
```

The second matters more than it looks: the unexpected field is refused rather than silently
stripped, and the rejection does not echo its name or its value back (§52, §57).

**What was not observed, in this run.** No 502, 503 or 500 was induced here — those paths are
covered by `apps/server/test/api/test-runs.test.ts` and by the live classification #53 recorded
against this same cluster, not by this document. Nor was the in-cluster identity path exercised;
see "Which identity the server uses".

## Which identity the server uses

`KubeConfig#loadFromDefault()` tries `KUBECONFIG`, then `~/.kube/config`, then the in-cluster
ServiceAccount token. A server started by `make -C apps/server start` on a developer machine takes
the **first or second** path, so the Job above was created by *your* kubeconfig's identity, not by
`sandcastle-server`.

That is the only path available today: there is no `sandcastle-system` namespace and no Deployment
for the server, so nothing yet runs as a Pod under that ServiceAccount. It arrives with the
workload it separates (`deploy/kubernetes/README.md`, "Why only one namespace").

The consequence is worth stating plainly rather than leaving implied: **this run does not prove
that `sandcastle-server`'s Role is sufficient.** A developer kubeconfig on k3s is usually
cluster-admin, and a permission the Role is missing would not show up here. What is proven is that
the Role grants `create` on Jobs in `sandcastle-agents` and nothing outside it, by
`kubectl auth can-i` (above, and #54). The two meet when the server runs as a Pod.

## The server has no preflight

`launch-run.sh` checks nine things before it applies anything — the cluster, the namespace, the
ServiceAccount, the node capability labels and the digest they were measured against, a run-ID
collision, and both Secrets. `POST /api/test-runs` checks **the request body, and nothing about
the cluster**: it validates three fields, renders the Job, and submits it.

That is a deliberate split, not an oversight — the endpoint's job is to submit, and the four
error classes it maps (`apps/server/README.md`'s status-code table) are what the API server tells
it. But it means a mistake the launcher would have refused becomes a `201` here and a Pod that
never runs:

| If | `launch-run.sh` | `POST /api/test-runs` |
| --- | --- | --- |
| no node is labelled capable | refuses before applying, naming `probe-nodes.sh` | `201`, then a Pod `Pending` until `activeDeadlineSeconds` (1800 s) fails the Job |
| a node was measured against another image | refuses before applying | `201`, and a possible SIGILL mid-run (exit 132) — `deploy/kubernetes/README.md`, "If a node lies" |
| a Secret is missing or misnamed | refuses before applying | `201`, then `CreateContainerConfigError` on the Pod |
| the namespace is missing | refuses before applying | **`502`** — the API server rejects the Job, which the server does classify |
| the cluster is unreachable | refuses before applying | **`503`** |

So step 1 of the procedure is not ceremony. When a `201` is followed by a Pod that does not run,
`deploy/kubernetes/README.md`'s "When a run fails" table is the diagnosis — it is written against
the same manifest, and every row in it was induced on this cluster.

## Cleanup (§47)

**What `job.yaml` handles by itself.** `ttlSecondsAfterFinished: 86400` — 24 hours after a Job
*finishes*, successfully or not, the TTL controller deletes the Job and its Pod.
`activeDeadlineSeconds: 1800` is what makes a Job that never starts a container finish at all, so
a Pod stuck in `ImagePullBackOff` or `Pending` is failed after half an hour and then reaped a day
later. Nothing leaks: every run is gone within 24½ hours at worst. `backoffLimit: 0` means one
attempt, because an agent run is not idempotent.

**What it does not handle.** Three things:

1. **§47 asks for two numbers and a Job has one.** The policy is an hour for a successful Job and
   a day for a failed one; `job.yaml` uses the longer of the two for both, because in Phase 3 the
   Pod is still the only record a run leaves — there is no database and no log collection, so
   reaping a failure after an hour would destroy the only evidence of it. The cost is that a
   **successful** Job lingers 23 hours longer than §47 wants. Deleting it by hand is the
   difference, which is why step 5 exists. Split the TTL into §47's two numbers once something
   outside the cluster keeps the logs (§38, §48).
2. **Deleting the Job deletes the logs.** They are the same object. Read what you need first;
   there is no second copy anywhere.
3. **Nothing else is a run's to remove.** The Secrets, the two ServiceAccounts, the RBAC, the
   namespace and the nodes' capability labels all outlive every run, and none of the commands here
   touch them.

```sh
kubectl -n sandcastle-agents get jobs                             # what is there
kubectl -n sandcastle-agents describe job sandcastle-<run-id>     # why it failed
kubectl -n sandcastle-agents logs -l sandcastle.run=<run-id>      # what it printed
kubectl -n sandcastle-agents delete job sandcastle-<run-id>       # now, rather than in 24h
kubectl -n sandcastle-agents delete job -l app=sandcastle         # every run at once
```

`delete job` cascades to the Pod: the Job controller sets a `metadata.ownerReferences` entry, and
`kubectl delete` honours it by default. Confirmed on 2026-09-18 — deleting the run above removed
its Pod with it, in the same command.

### A `Failed` Job that is still there is not necessarily a leak

On 2026-09-18 this cluster held one Job older than any of this work:
`sandcastle-run-20260918-003624-fa2cba`, `Failed`, 19 hours old, its Pod `Error` with exit **132**
on node `nova` — #30's SIGILL, from before `probe-nodes.sh` had labelled that node `false`.

**It was deliberately left alone, and that is the general answer.** Its `ttlSecondsAfterFinished`
is 86400 and its `Failed` condition transitioned at `00:36:34Z`, so it is *inside* §47's 24-hour
retention window for a failed Job, not escaping it — the TTL controller reaps it around
`00:36:34Z` the next day. Deleting it early would have destroyed exactly the diagnostic §47 keeps
a failure for a day in order to preserve, and in Phase 3 there is nowhere else that evidence
exists.

So, when you find a lingering Job:

| What it is | What to do |
| --- | --- |
| `Failed`, inside 24 hours of failing | leave it — that is the policy working. Read it: `describe job`, `logs` |
| `Failed`, well past 24 hours | the TTL controller is not running or the Job carries no TTL. Delete it by hand, then find out which — a Job applied from an edited manifest is the usual cause |
| `Complete`, any age | delete it. §47 wants an hour and the manifest gives it a day; step 5 is the difference |
| `Running`, past `activeDeadlineSeconds` (30 min) | it should have been failed already. `describe job` — if the Job controller is wedged, `delete job` ends it |

## What Phase 3 does not give you

In the spirit of `deploy/kubernetes/README.md`'s "What these checks do not cover" — honest rather
than reassuring.

**No persistence.** `POST /api/test-runs` writes nothing down. There is no Run record, no database
row, no `GET /api/runs/:id`, and no way to ask the server about a run it created a second ago.
The `sandboxId` in the 201 response is the entire handle, and the server forgets it before the
response is flushed. Lose it and `kubectl get jobs` is your index. Run persistence is §38.

**No log streaming.** The server never reads the Pod's logs. `KubernetesSandboxRuntime`
implements `create()` and nothing else — `get`, `stop`, `logs` and `cleanup` all throw
`not implemented yet`, naming §38. So the §48 structured-log fields (`run_id`, `pod_name`,
`agent`, …) have no emitter here: the server logs the HTTP request and, on a failure, the
cluster's own reason. The run's output exists only in the Pod, only until the Job is deleted, and
only through `kubectl logs`.

**No run states.** §38's `creating / starting / running / completed / failed` do not exist.
Kubernetes' own Job and Pod phases are the only status there is, and reading them is `kubectl`.

**No cancellation.** `POST /api/runs/:id/stop` (§33) is not here, and `stop()` throws. To end a
run in flight, delete its Job.

**`kubectl` is therefore the only view of a run's progress.** Every "watch it" instruction above
is a `kubectl` command for that reason, not for lack of polish. An operator without cluster access
cannot see anything past the `201`.

**No webhook, no UI, no GitHub result.** A run is started by `curl`, not by an `agent:run` label
(Phase 5, §39), and its branch is committed inside the Pod and never pushed — the run says so in
its own last log line. Phase 6 (§40) is what makes the work leave the cluster. Until then a
successful run's output is destroyed with its Pod, by design rather than by accident.

**The route's name is temporary.** §37 names it `POST /api/test-runs`; §33's Initial API has
`/api/runs` with verbs this endpoint cannot do yet. Whichever issue implements §38 renames it —
see `apps/server/src/api/test-runs.ts`'s header.

**This document records one run.** It is not a standing check, nothing in CI runs it, and it
cannot be: it needs a cluster and two real credentials. The same limit `deploy/kubernetes/README.md`
states for its own live findings applies here — what is written under "What was observed" was true
of that commit, that image digest and that cluster on that day.
