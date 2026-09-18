# Kubernetes manifests for an agent run

Phase 2 (docs/ARCHITECTURE.md §36): the Phase 1 container, run as a Kubernetes Job, by hand,
with no Sand Castle server involved. See §19 (Job, not Pod), §20 (the example Job), §21
(namespace), §23 (resource limits), §24 (workspace), §47 (cleanup) and §50 (security
boundaries).

The server's own identity and RBAC (§22) live here too, ahead of the server itself: #54 built
them so #53 has something to submit a Job as, independently of the server's own code. See "The
server's identity" below.

```text
deploy/kubernetes/
├── namespace.yaml               the sandcastle-agents namespace every run lives in (§21)
├── serviceaccount.yaml          the run's identity, with no Kubernetes API token (§50)
├── server-serviceaccount.yaml   the server's identity (§22, §50) -- see "The server's identity"
├── server-role.yaml             what that identity may do, and no more (§22)
├── server-rolebinding.yaml      what binds the two above together
├── job.yaml                     one run, as a Job template with three placeholders (§19, §20)
└── scripts/
    ├── create-secrets.sh the two credential Secrets the Job reads (§14, §15)
    ├── render-job.sh     substitutes the placeholders; the renderer on this side
    ├── launch-run.sh     runs one run and follows it; the Phase 2 command (§36)
    ├── probe-nodes.sh    measures which nodes can run the agent binary, and labels them (#30)
    ├── validate.sh       kubeconform + property assertions; what CI runs
    ├── prove-checks.sh   breaks each property and requires validate.sh to notice
    └── check-jsonpath.sh checks every jsonpath field path against the cluster's schema (#28)
```

No Helm chart, no Kustomize overlays, no templating engine. §36 is one Job run by hand and §54
is explicit that the CRD is not to be built first; the same restraint applies to packaging.
`launch-run.sh` is a shell script over `kubectl`, not the beginning of a controller: §37 is
where a server first creates a Job.

## The other renderer

The Phase 3 server builds this same Job itself, as a TypeScript object rather than as text:
`apps/server/src/kubernetes/job-builder.ts` (#52). Two renderers of one manifest is the shape
that produced #26, so this one is a deliberate, bounded exception rather than an oversight:

- **Why both.** A server that submits a Job to the Kubernetes API has no use for rendered YAML,
  and an operator on a cluster with no server running — which is every cluster until #53 lands —
  has no use for a TypeScript build. `launch-run.sh`, `validate.sh` and `prove-checks.sh` all go
  through `render-job.sh` today, and Phase 2 is the path that works.
- **What stops them drifting.** `apps/server/test/kubernetes/job-builder.test.ts` runs
  `render-job.sh` for real, parses what it printed, and requires it to equal what the builder
  returns, field for field — including the pinned image digest. A change made to `job.yaml` and
  not to the builder (or the reverse) turns the `server-test` check red. It is not a review
  convention; it is a check.
- **When they converge.** Once §37's `POST /api/test-runs` is how a run starts, the server is the
  renderer every run goes through and these manifests become the manual fallback. That is the
  point to decide whether `job.yaml` stays a template or becomes documentation — not before,
  while deleting it would leave Phase 2 with no way to start a run at all.

So: edit `job.yaml` and the builder together, and let the test tell you when you have not.

## Running one

Once, to set the cluster up:

```sh
kubectl apply -f deploy/kubernetes/namespace.yaml
kubectl apply -f deploy/kubernetes/serviceaccount.yaml
kubectl apply -f deploy/kubernetes/server-serviceaccount.yaml
kubectl apply -f deploy/kubernetes/server-role.yaml
kubectl apply -f deploy/kubernetes/server-rolebinding.yaml
./deploy/kubernetes/scripts/create-secrets.sh                # see "Credentials" below
./deploy/kubernetes/scripts/probe-nodes.sh                   # see "Which nodes can run the agent"
```

The last one is not optional and is not a one-off: **until it has run, nothing schedules at
all**, and it has to run again whenever a node joins the cluster or `job.yaml`'s image digest
changes.

Then, per run:

```sh
./deploy/kubernetes/scripts/launch-run.sh <owner/repo> <issue-number>
```

That renders `job.yaml` for a fresh run ID, applies it, follows the Pod's logs live, and exits
with the run's result. It is the cluster counterpart of `images/agent/scripts/smoke.sh` and
behaves like it: the environment beats the arguments (`GITHUB_REPOSITORY`,
`GITHUB_ISSUE_NUMBER`, `AGENT`, and `RUN_ID` to override the generated run ID), validation
happens before anything is applied, and **no credential is ever an argument**. It needs none of
its own -- see "No credential passes through the launcher" below.

Its exit status is the run's:

| Status | Meaning |
| --- | --- |
| `0` | the agent ran and exited 0 |
| `64` | the arguments are wrong (`EX_USAGE`); nothing was applied |
| `69` | the run never ran, or the cluster ended it (`EX_UNAVAILABLE`) |
| anything else | the agent's own exit code |

The message is always the authority on which layer failed; the code is for whatever wraps the
script. Three environment variables tune the waiting, and exist because a cold image pull and a
hung scheduler need different patience:

- `SANDCASTLE_START_TIMEOUT` (default `300`) bounds **each** of the two waits before the logs
  start -- the Job producing a Pod, and that Pod's container starting -- so a run that stalls in
  both spends up to twice it before the launcher gives up. They are separate waits because they
  fail for different reasons and get different messages, and one number is enough for both:
  neither is a deadline on the run, which is `activeDeadlineSeconds`' job (§23).
- `SANDCASTLE_FINISH_TIMEOUT` (default `60`) bounds the wait after the logs end for the Pod's
  exit status to appear.
- `SANDCASTLE_POLL_INTERVAL` (default `2`) is how often each of those three asks.

### By hand, without the launcher

The same four steps, if you want to watch the pieces:

```sh
./deploy/kubernetes/scripts/render-job.sh <run-id> <owner/repo> <issue-number> | kubectl apply -f -
kubectl -n sandcastle-agents get job -l sandcastle.run=<run-id>
kubectl -n sandcastle-agents logs -f -l sandcastle.run=<run-id>
```

`render-job.sh` validates what it substitutes -- the run ID must be a DNS-1123 label short
enough to prefix, the repository must be `owner/repo`, the issue must be a positive integer --
and refuses an empty value rather than rendering `sandcastle-` and a Job that collides with the
next one. `launch-run.sh` adds no validation of its own on top of it; it calls it and inherits
its messages.

Unlike `launch-run.sh` above, an argument passed to `render-job.sh` directly wins over an
already-set environment variable of the same name -- the argument is the more specific
statement of intent, and an environment variable that is set but empty counts as not set at
all (#64).

The one thing the launcher checks that these commands do not is the **agent**: it takes
`[agent]` as a third argument and compares it with what `job.yaml` sets, rather than
substituting it. `AGENT` is deliberately not a placeholder (see "Running Codex instead of
Claude"), so asking for an agent the manifest does not run is refused rather than half-done.

## The server's identity

`sandcastle-server` (§22, §50) -- not `sandcastle-agent`, which is a different identity for a
different actor and must stay that way (see serviceaccount.yaml's own header). This is what #53
will submit a Job as, once the server exists to do it; #54 built the identity and its
permissions first and independently, so that work is not blocked on the server's own code.

**What it is.** A ServiceAccount, a Role and a RoleBinding, all in `sandcastle-agents` (§21) --
`server-serviceaccount.yaml`, `server-role.yaml` and `server-rolebinding.yaml`. Three files, not
one: they are three distinct Kubernetes objects that only do anything bound together, but this
directory's convention is one kind per file (`namespace.yaml`, `serviceaccount.yaml`,
`job.yaml`), `validate.sh` asserts every manifest here holds exactly one document so a second
object can never ride along inside a file unexamined, and the order they are applied in does not
matter -- so there was nothing to gain by combining them and a property to lose. See
`server-role.yaml`'s header for the fuller version of this reasoning.

**What it may do.** Exactly §22's list, minus `pods/exec` (§22 defers that). `server-role.yaml`
writes the granted verbs as two groups per resource, so the distinction below is visible in the
manifest itself and not only here:

| Verb | Resource | In use |
| --- | --- | --- |
| `create` | `jobs` | **yes** -- §37's `POST /api/test-runs` is the only thing that calls this Role today |
| `get`, `list`, `watch`, `delete` | `jobs` | not yet -- granted ahead of use; §38 and §47 are what will call these |
| `get`, `list`, `watch` | `pods` | not yet -- granted ahead of use, for the same reason |
| `get` | `pods/log` | not yet -- granted ahead of use; this is the `pods/log` *subresource*, not a verb on `pods` |

Granting the whole list now, rather than one verb per issue, is what §22 explicitly permits: one
reviewed change instead of five. What it does not permit is hiding that only `create` is live,
which is why the split above exists.

**What it deliberately may not.** `pods/exec` (§22 defers it), anything cluster-scoped
(`server-role.yaml` is a `Role` and `server-rolebinding.yaml` is a `RoleBinding`, never their
`Cluster*` counterparts -- §22: "do not grant cluster-admin"), and anything outside
`sandcastle-agents`: all three objects are namespaced to it, and a `Role`'s permissions cannot
reach beyond the namespace it lives in regardless of what binds to it.

**How an operator applies it.** The three `kubectl apply` lines in "Running one" above, in any
order, once per cluster -- the same one-time step as the namespace and the agent's
ServiceAccount, and for the same reason: nothing here changes per run.

**Why this ServiceAccount lives in `sandcastle-agents`, not `sandcastle-system`.** §21 names
`sandcastle-system` for the server's own workload, and that namespace does not exist in this
repository yet -- "Why only one namespace" below is still accurate; it arrives with the
Deployment it is meant to separate. A RoleBinding's subject can name a ServiceAccount in a
different namespace from the one the binding grants in, so nothing here has to change when
`sandcastle-system` and a Deployment for the server do arrive; only where the *Pod* that
authenticates as `sandcastle-server` runs would be new, not this identity or what it may do.

**Verifying it, with a cluster.** `kubectl auth can-i` answers exactly the acceptance criterion
this issue was given -- "can create a Job in `sandcastle-agents` and cannot create one
elsewhere":

```sh
kubectl auth can-i create jobs --as=system:serviceaccount:sandcastle-agents:sandcastle-server -n sandcastle-agents   # yes
kubectl auth can-i create jobs --as=system:serviceaccount:sandcastle-agents:sandcastle-server -n default             # no
kubectl auth can-i '*' '*' --as=system:serviceaccount:sandcastle-agents:sandcastle-server -A                        # no (no cluster-admin, anywhere)
```

## Which nodes can run the agent

`job.yaml` will only schedule a run onto a node labelled `sandcastle.dev/agent-capable=true`:

```yaml
nodeSelector:
  sandcastle.dev/agent-capable: "true"
```

**Why the image's own `linux/amd64` is not enough.** The Claude Code CLI ships as a Bun
single-file executable, and Bun's modern x86-64 build requires AVX2. An image manifest list
cannot express that: `amd64` is the finest thing it can say, and this cluster's two amd64 nodes
are not equivalent.

| node | CPU | AVX2 | `claude --version`, same image digest |
| --- | --- | --- | --- |
| `red` | Core i7-6700 (Skylake, 2015) | yes | `2.1.236 (Claude Code)`, exit 0 |
| `nova` | Core 2 Duo P8800 (2009) | no | nothing at all, exit **132** |

132 is 128+4, SIGILL. Before the `nodeSelector`, nothing constrained which of the two a run
landed on, so the same command succeeded or failed by coin flip -- and the failure arrived
*after* the clone, the branch and the issue fetch had all worked, looking exactly like a bug in
the agent. That is the worst shape a bug can have, and it is the reason this section exists.

### The label is measured, not asserted

```sh
./deploy/kubernetes/scripts/probe-nodes.sh            # probe every node and label each
./deploy/kubernetes/scripts/probe-nodes.sh red nova   # probe only these
./deploy/kubernetes/scripts/probe-nodes.sh --show     # what the cluster says now; changes nothing
```

`probe-nodes.sh` runs the **real binary** on each node: a one-container Pod, pinned to that node,
from the exact image digest `job.yaml` pins, whose command is `claude --version`. That command
makes no provider call, needs no credential and prints a version string, so the Pod carries no
Secret and no environment at all. The node is then labelled by what happened:

| what the container did | label | why |
| --- | --- | --- |
| exited 0 | `true` | the binary ran here |
| exited non-zero (132 is SIGILL) | `false` | the binary is here and cannot run |
| never ran -- image unpullable, Pod never started, timeout | *unchanged* | nothing was measured |

That third row is the point. An image that never arrived says nothing about whether the node
could have executed it, so the probe writes no label, says `NOT MEASURED`, and exits non-zero;
whatever the node claimed before, it still claims, and `--show` will say which image that claim
was about.

The alternative was a hand-applied label, which is two lines of `kubectl` and no script. It was
rejected because it is an operator's **claim**, and a wrong claim reproduces this bug exactly --
the label would say `true`, the scheduler would believe it, and the run would SIGILL. A check on
the CPU's AVX2 flag was rejected for a weaker version of the same reason: it tests a proxy for
today's cause, and the next incompatibility will be some other instruction, a glibc version or a
kernel feature. Running the binary is the only question worth asking, and it costs one Pod start
per node, perhaps twice a year.

The probe's own costs, stated rather than hidden:

- **It is about one image.** See the next section.
- **A node added later is unlabelled**, and therefore invisible: runs keep going to the nodes
  that are labelled, and nobody is told the new node is idle. Exclusion is the safe direction --
  the failure is capacity, not a SIGILL -- but it is a thing to remember when a node joins.
- **It needs cluster-scoped permission** to list, label and annotate nodes, which is more than
  `launch-run.sh` otherwise asks for. The probe is an operator's tool, not part of a run.
- **It uses `nodeName`, deliberately skipping the scheduler.** It has to: a node with no
  capability label is one `job.yaml`'s own selector excludes, so a scheduled probe could never
  measure a node that had not already been measured, and a cordoned node could not be measured
  at all.

### A label is an answer about one image

`job.yaml`'s digest moves (`§20`: an immutable digest, updated deliberately), and a node
verified against last month's image is a `true` about a binary this run will not execute. Since
nothing in Kubernetes notices that -- the selector matches the label, not the reason for it --
the probe records what it measured beside the label:

```text
sandcastle.dev/agent-capable        true                     (a label, so the selector can match it)
sandcastle.dev/agent-capable-image  ghcr.io/…@sha256:de6e…   (an annotation: what was measured)
```

An annotation rather than a richer label value, for two reasons: a label value is capped at 63
characters and `ghcr.io/pmhood/sandcastle-agent@sha256:<64 hex>` does not fit, and folding the
digest into the value would put the digest in `job.yaml` twice and turn a stale cluster into
"no node matched a selector" rather than into what it is.

`launch-run.sh` compares the two **before it applies anything**, and **refuses** the run if any
node it could be scheduled onto was measured against a different image -- or carries the label
with no recorded image at all, which is what a hand-applied one looks like. Those are two
different mistakes and get two different messages, because the operator will find two different
things when they go and look: an annotation naming an older digest, or no annotation whatsoever.
The fix is the same command either way.

A refusal rather than a warning, and the asymmetry is the argument. A stale label costs an
intermittent SIGILL that presents as an agent bug; re-probing costs one command and about a
minute. A warning would arrive in the middle of a launch that then appears to proceed, which is
exactly when nobody reads it. And it is *every* candidate node that has to agree, not just one,
because the scheduler chooses among all of them: "mostly verified" is the coin flip this whole
section is about.

Not being able to *look* is treated differently from seeing a mismatch. Listing nodes is
cluster-scoped and nothing else the launcher does is, so a kubeconfig that may not read them
gets a line saying so and the run proceeds -- the scheduler still enforces the `nodeSelector`,
and the failure below still explains it. Absence of evidence is not evidence.

### What it looks like when nothing is labelled

On a cluster nobody has probed, **no run schedules at all**. That is the safe direction, and it
would be mysterious if it were silent, so it is said twice. Before anything is applied:

```text
[LAUNCH] FAILED at the capability layer: no node carries sandcastle.dev/agent-capable=true, and
[LAUNCH] job.yaml schedules a run onto nothing else
[LAUNCH]   Fix: ./deploy/kubernetes/scripts/probe-nodes.sh runs `claude --version` on each node
[LAUNCH]        and labels what actually happened
```

and if a Job reaches the scheduler anyway -- applied by hand, or a label removed while the run
was starting -- the scheduler's own sentence is quoted with what it does not say added:

```text
[LAUNCH] Pod is not scheduled yet: 0/2 nodes are available: 2 node(s) didn't match Pod's node
[LAUNCH] affinity/selector. …
[LAUNCH]   no node carries sandcastle.dev/agent-capable=true, and job.yaml only schedules onto
[LAUNCH]   one that does. Measure them: ./deploy/kubernetes/scripts/probe-nodes.sh
```

That second message is worth the code it takes. The scheduler says *"didn't match Pod's node
affinity/selector"* for a taint, for a busy cluster and for this, identically, and on a cluster
nobody has probed it is every node at once -- which reads as a broken cluster rather than as a
step nobody has run yet.

### If a node lies

Nothing stops an operator labelling a node by hand, and the label is trusted by the scheduler
the moment it exists. A `true` on a node that cannot run the binary produces exactly #30 again:

```text
[SANDCASTLE] Environment validated
[GIT] Cloning pmhood/alpine from https://github.com
[GITHUB] Issue #1: Add a README.md
[CLAUDE] Starting Claude Code CLI in /workspace/repo
/usr/local/bin/runners/claude.sh: line 14:    33 Illegal instruction     (core dumped) claude …
[CLAUDE] Claude Code CLI exited with status 132
[SANDCASTLE] Run run-20260918-003624-fa2cba failed
[LAUNCH] FAILED at the node layer: SIGILL killed the run on node nova (exit 132 is 128+4, and no signal was reported)
[LAUNCH]   Fix: node nova cannot execute this build of the agent binary -- SIGILL is an
[LAUNCH]        instruction its CPU does not have (#30). …
[LAUNCH]   Kubernetes said:
[LAUNCH]     terminated: reason Error, exit code 132
```

Everything works, and then the agent dies partway through the one step that matters.
**Exit 132 from a run means read this section**, and the first thing to run is `probe-nodes.sh
--show`, then `probe-nodes.sh`. A hand-applied label is caught before the run these days,
because it carries no `sandcastle.dev/agent-capable-image` annotation and the launcher refuses a
`true` with no provenance -- but a label hand-applied *with* a matching annotation is still a
claim nobody measured, and nothing here can see that.

**A run Pod and a probe Pod report a SIGILL differently, and the difference is load-bearing.**
A run Pod's PID 1 is `sandcastle-run`, a bash script (§12), and the agent CLI is its child. When
the child dies of SIGILL, that bash reaps it and prints the `Illegal instruction (core dumped)`
job line above on its own stderr -- unprefixed, because it is bash talking rather than the
bootstrap, and naming `runners/claude.sh` because that is the file the sourced `invokeAgent`
came from. `pipefail` then makes the pipeline's status 132, and the bootstrap exits with it
deliberately. So the run's log *does* name the signal, and the container's status is a shell
propagating 132 rather than a signal death of PID 1 -- which is exactly what the launcher's
fallback relies on, because no runtime here fills in `state.terminated.signal` and 128+n is what
this image actually produces (see "When a run fails"). A **probe** Pod has no shell at all --
its command is `["claude", "--version"]`, so the binary *is* PID 1 -- and there SIGILL leaves no
output whatsoever: `probe-nodes.sh` names the 132 in its own message precisely because nothing
else will.

## What a successful run prints

`[LAUNCH]` lines go to stderr; the run's own output is relayed to stdout verbatim, already
carrying the §31 prefixes the bootstrap gave it. The two can therefore be separated, and
nothing rewrites the Pod's logs on the way through.

```text
[LAUNCH] Run run-20260917-021433-165e55
[LAUNCH]   Repository: octocat/Hello-World
[LAUNCH]   Issue:      #1
[LAUNCH]   Agent:      claude
[LAUNCH]   Image:      ghcr.io/pmhood/sandcastle-agent@sha256:de6e6b92…
[LAUNCH]   Namespace:  sandcastle-agents
[SECRETS] sandcastle-github-token: key 'token' present, 40 bytes (value not shown)
[SECRETS] sandcastle-claude-oauth: key 'token' present, 108 bytes (value not shown)
[SECRETS] Both Secrets are present with the keys job.yaml expects
[LAUNCH] Applying sandcastle-run-20260917-021433-165e55
[LAUNCH]   job.batch/sandcastle-run-20260917-021433-165e55 created
[LAUNCH] Pod sandcastle-run-20260917-021433-165e55-jz682 created
[LAUNCH] Following sandcastle-run-20260917-021433-165e55-jz682 (stdout below is the run's own)

[SANDCASTLE] Environment validated
[SANDCASTLE] Run run-20260917-021433-165e55 started
[GIT] Cloning octocat/Hello-World from https://github.com
[GITHUB] Issue #1 read
[CLAUDE] Starting Claude Code CLI
…
[LAUNCH] Run run-20260917-021433-165e55 PASSED: the agent exited 0
```

The `[SECRETS]` lines are `create-secrets.sh --verify`, which the launcher runs as its
credential preflight rather than having a second opinion about what the Secrets are called.

## When a run fails

This is the section §36 is really for. A run that produces no result looks the same from
outside whatever the reason -- a Pod that never starts is a Pod that never starts -- so the
launcher names the **layer** and what to do, and quotes what Kubernetes said underneath it,
labelled as such. An operator should never have to read `kubectl describe` output to find out
that a Secret key was misspelled.

```text
[LAUNCH] FAILED at the image layer: the image has no build for this node's architecture
[LAUNCH]   Fix: publish the image for this node's platform (images/agent CI builds linux/amd64
[LAUNCH]        and linux/arm64), or schedule the run on a node it was built for
[LAUNCH]   Kubernetes said:
[LAUNCH]     rpc error: code = NotFound desc = failed to pull and unpack image
[LAUNCH]     "docker.io/arm64v8/alpine:3.20": no match for platform in manifest: not found
```

Every row below was induced on the k3s cluster with obviously fake values, and the strings the
launcher matches are what Kubernetes actually said rather than what it seemed likely to say.

| Layer | What happened | How it is detected | Likeliest fix |
| --- | --- | --- | --- |
| `kubectl` | no `kubectl` on `PATH` | `command -v` | install it, set `KUBECONFIG` |
| `cluster` | the cluster is not reachable | `kubectl get namespace` stderr: `Unable to connect`, `connection refused`, `no such host` | check `KUBECONFIG`, check the cluster is up |
| `cluster` | this kubeconfig may not look | the same stderr: `Unauthorized`, `forbidden` | use a context with access to the namespace |
| `cluster` | the namespace is missing | the same call, any other error | `kubectl apply -f namespace.yaml` |
| `cluster` | the ServiceAccount is missing | `kubectl get serviceaccount` before applying | `kubectl apply -f serviceaccount.yaml` |
| `capability` | no node is labelled able to run the agent binary | `kubectl get nodes -l sandcastle.dev/agent-capable=true` before applying | `probe-nodes.sh` |
| `capability` | a candidate node was measured against another image | the same nodes' `sandcastle.dev/agent-capable-image` vs `job.yaml`'s digest | `probe-nodes.sh` again; `--show` says which image each carries |
| `capability` | a candidate node carries the label with no image recorded at all -- a hand-applied one | the same annotation, absent | `probe-nodes.sh`, to measure what the label claims |
| `cluster` | the run ID is already a Job | `kubectl get job` before applying | pick another `RUN_ID`, or delete that Job |
| `credentials` | a Secret is missing, misnamed, or holds the wrong key | `create-secrets.sh --verify`, before applying | `create-secrets.sh` |
| `cluster` | the API server refused the Job | non-zero `kubectl apply` | `validate.sh`, then fix `job.yaml` |
| `admission` | the Pod will be refused by Pod Security Admission | `would violate PodSecurity` in `apply`'s output | restore the §50 security context |
| `admission` | the Pod *was* refused by admission | the Job's `FailedCreate` event: `violates PodSecurity` | as above |
| `cluster` | the ServiceAccount vanished after preflight | the same event: `error looking up service account` | `kubectl apply -f serviceaccount.yaml` |
| `image` | the registry has no such image | `ErrImagePull`/`ImagePullBackOff` + `not found`, `failed to resolve reference` | check the digest pinned in `job.yaml` |
| `image` | the registry refused the pull | the same + `failed to authorize`, `403 Forbidden`, `denied` | make the GHCR package public, or add an `imagePullSecret` |
| `image` | no build for this node's architecture | the same + `no match for platform` | publish for the node's platform, or move the run |
| `credentials` | a Secret or key the Pod needs is not there | `CreateContainerConfigError`, whose message names the Secret *or the key* | `create-secrets.sh --verify`, compare with `job.yaml` |
| `runtime` | the container could not be created | `CreateContainerError`, `RunContainerError` | read the quoted runtime message |
| `runtime` | the container's process could not start | terminated `StartError` | the image's entrypoint, not the agent |
| `runtime` | it exceeded its memory limit | terminated `OOMKilled` (exit 137) | raise the memory limit (§23) |
| `node` | **SIGILL**: the node cannot execute the binary | terminated `signal` 4, else exit 132 | `probe-nodes.sh`; the node is labelled capable and is not |
| `runtime` | **SIGABRT, SIGBUS, SIGFPE, SIGSEGV**: the process faulted | terminated `signal` 6, 7, 8, 11 -- else exit 134, 135, 136, 139 | the run's own output, where it stops |
| `runtime` | **any other signal, SIGKILL included** | terminated `signal`, else exit 128+n | something outside the run ended it; `describe pod`, check the node |
| `scheduling` | no node could take the Pod | `PodScheduled=False`, reason `Unschedulable` | free capacity, or lower the requests (§23) |
| `scheduling` | …and no node matched the selector | the same, message `didn't match Pod's node affinity/selector` | `probe-nodes.sh` ("Which nodes can run the agent") |
| `scheduling` | the node evicted the Pod | Pod phase `Failed`, reason `Evicted` | node pressure; retry or give it room |
| `timeout` | it hit `activeDeadlineSeconds` | the **Job's** condition `DeadlineExceeded` | raise it in `job.yaml` if the work is genuinely longer |
| `cluster` | no Pod within `SANDCASTLE_START_TIMEOUT` | nothing else fired | `kubectl describe job` |
| `cluster` | no container started within it | nothing else fired | `kubectl describe pod` |
| **`agent`** | **the run started and exited non-zero** | terminated `Error`, a non-zero exit code, and no signal | the run's own output above; the run chose that status |

Seven of those are worth their own paragraph.

**The two `capability` rows are the only ones checked before a Job exists that are not about
this cluster's furniture.** They are there because the alternative is a Pod that sits `Pending`
for `SANDCASTLE_START_TIMEOUT` seconds while the scheduler says a sentence that names neither
the label nor what to do about it. See "Which nodes can run the agent".

**The architecture mismatch is tested before the missing image**, because its message also ends
in `not found`. It is the failure that looks least like what it is: the digest is right, the
registry is right, and the node simply cannot run any image in the manifest list.

**`activeDeadlineSeconds` erases its own evidence.** The Job controller deletes the Pod, so the
deadline can only be read from the Job's conditions -- and it has to be read *wherever* a Pod is
being waited for, because a deadline that expires before the Pod is even scheduled otherwise
looks exactly like a Pod that never appeared. An earlier draft of the launcher reported it as
"the Job created no Pod", which is true and useless.

**Pod Security Admission runs against the Pod, not the Job.** A Job that violates the profile is
*accepted*, with a warning on `kubectl apply`, and then never produces a Pod. The launcher fails
on that warning rather than waiting out the start timeout to say the same thing.

**An image pull failure is reported the first time it is seen.** A genuinely transient registry
outage therefore surfaces here too; the quoted message is what tells the two apart, and
re-running is the answer.

**A signal is not an exit status the run chose**, and the three signal rows exist because the
classifier used to have no branch for that at all (#31). It read `reason: Error` with a non-zero
code as the agent's own failure and said so confidently -- "the container ran, so this is not a
cluster problem" -- for a run that had died of `Illegal instruction` on a node whose CPU cannot
execute the agent binary. Both halves were wrong: it was the node, and the run's own output
could not explain it as an agent failure -- every §31 stage the bootstrap reports had succeeded,
and the last line before the end was bash naming a signal, not the agent naming a problem. (The
run's output is not *silent* on a SIGILL, which "If a node lies" now sets out: a run Pod has a
shell for PID 1 and a probe Pod does not. It says the wrong thing, not nothing.) The grouping is
the design. SIGILL means this hardware cannot run this binary and points at `probe-nodes.sh`;
SIGSEGV, SIGABRT, SIGBUS and SIGFPE all mean the process faulted and all point at the run's
output, so they share one message and each prints its own name; everything else, SIGKILL
included, means something outside the process ended it -- and SIGKILL keeps its OOM answer,
because `reason: OOMKilled` is matched before any of this.

**How a signal is detected is worth knowing, because it is not perfect.** `state.terminated.signal`
is the authority where a runtime fills it in: it says a signal ended the container, and it is
read before the exit code, so a container that genuinely exits 132 on such a runtime is not
mistaken for SIGILL. containerd -- what k3s runs here -- fills in nothing: a container whose PID
1 was killed by SIGILL on `nova` and a container that ran `exit 132` report the same `reason`,
the same code and no signal, field for field. So the second reading is the 128+n convention,
which is also what this image actually produces: its PID 1 is the bootstrap, a shell, and a
shell whose child dies of signal *n* exits 128+*n* itself, which is exactly what the run behind
#31 did. The launcher says which of the two readings it used, in the message, so an operator can
disagree with it:

```text
[LAUNCH] FAILED at the node layer: SIGILL killed the run on node nova (exit 132 is 128+4, and no signal was reported)
[LAUNCH]   Fix: node nova cannot execute this build of the agent binary -- SIGILL is an
[LAUNCH]        instruction its CPU does not have (#30). ./deploy/kubernetes/scripts/probe-nodes.sh
[LAUNCH]        runs `claude --version` from job.yaml's image on each node and labels what
[LAUNCH]        happened, so a node the binary dies on ends up
[LAUNCH]        sandcastle.dev/agent-capable=false and takes no run
[LAUNCH]   Kubernetes said:
[LAUNCH]     terminated: reason Error, exit code 132
```

## Teardown

`ttlSecondsAfterFinished: 86400` cleans up after itself: 24 hours after a Job **finishes** --
successfully or not -- the Job and its Pod are deleted by the TTL controller, and with them the
only copy of the run's logs (§47, and see "Decisions worth their own paragraph").

The TTL clock starts when the Job *finishes*, which a Job that never starts a container does
not do on its own. `activeDeadlineSeconds: 1800` is what makes those finish: it is a deadline on
the **Job**, not on the container, so it fails a Job that is stuck in `ImagePullBackOff` or
whose Pod admission keeps refusing just as it fails a run that is taking too long -- confirmed
on the cluster, where a one-second deadline failed a Job before its Pod had been scheduled.
So nothing here leaks: every run is reaped within half an hour plus a day, at worst. Half an
hour is a long time to leave a Job that is plainly not going anywhere, so every failing launch
prints the three commands for the run it just left behind:

```sh
kubectl -n sandcastle-agents describe job sandcastle-<run-id>   # why
kubectl -n sandcastle-agents logs -l sandcastle.run=<run-id>    # what it printed
kubectl -n sandcastle-agents delete job sandcastle-<run-id>     # now, rather than in 24h
```

Deleting the Job deletes its Pod: ownership is a `metadata.ownerReferences` entry the Job
controller sets, and `kubectl delete job` cascades by default. To clear out every finished run
at once:

```sh
kubectl -n sandcastle-agents delete job -l app=sandcastle
```

The Secrets, the ServiceAccount, the namespace and the nodes' capability labels are not a run's
to remove and none of these touch them. The labels in particular live on the nodes rather than
in the namespace, so removing the namespace does not remove them: `kubectl label node <name>
sandcastle.dev/agent-capable-` and `kubectl annotate node <name>
sandcastle.dev/agent-capable-image-` are how they go, and after that nothing schedules until
`probe-nodes.sh` runs again.

## No credential passes through the launcher

`launch-run.sh` takes no credential, reads none, and needs none: the run's two credentials reach
the Pod through the `secretKeyRef` entries `job.yaml` already carries, which the kubelet resolves
from the Secrets `create-secrets.sh` put in the cluster (§15, §52). There is no value in the
launcher to put in argv, in the applied manifest, or in a log line.

That is a property to keep rather than a happy accident, so it is asserted the way #2's rule is
asserted everywhere else here: `images/agent/bootstrap/test/launch.bats` runs the launcher with
obviously-fake credentials exported into its environment -- the shape an operator's shell is
actually in -- against the recording `kubectl` that `helpers.bash` binds on `PATH` at load time,
and refutes both canaries in three places at once: everything that reached `kubectl`'s argv,
everything that reached its stdin (which is where the rendered Job goes), and everything the
launcher printed. Because three refutations would also pass against records that were simply
empty, a fourth test *requires* the run ID and the digest-pinned image to be in the same two
records.

## Credentials

Two, and no more (§36). Sand Castle knows a secret *name*, a *key* and a *credential type*; it
never knows a value (§14, §15).

| Secret | Key | Environment variable | What it is, and where to get it |
| --- | --- | --- | --- |
| `sandcastle-github-token` | `token` | `GITHUB_TOKEN` | A **scoped** GitHub token the run clones with and reads the issue with (§17). GitHub → Settings → Developer settings → Personal access tokens. Give it the one repository the run works in, not the account. Not the Sand Castle server's own credential, and not your everyday token. |
| `sandcastle-claude-oauth` | `token` | `CLAUDE_CODE_OAUTH_TOKEN` | The OAuth token Claude Code authenticates with (§13, §14), from `claude setup-token`. That command prints a **banner around** the token; the token is the single line inside it, and pasting the whole banner is the mistake that broke Phase 1's first real run. |

`sandcastle-claude-oauth` / `token` is the name §15 uses verbatim. Both are referenced from
`job.yaml` without `optional: true`, so a missing Secret or key stops the Pod starting instead
of handing the CLI an empty string -- see
[Never an empty credential](#never-an-empty-credential).

**The values live in exactly two places: the operator's environment (or their git-ignored
`images/.env.local`) and the cluster.** Never in this repository, never in a manifest, never in
a log line, never in a shell history file, and never in a command-line argument.

### Creating them

`create-secrets.sh` reads both credentials from the environment, or from the git-ignored
`images/.env.local` that `images/agent/scripts/smoke.sh` already uses, in the same `KEY=VALUE`
form. It takes no credential arguments and never will.

```sh
export GITHUB_TOKEN=...              # or put both in images/.env.local
export CLAUDE_CODE_OAUTH_TOKEN=...
./deploy/kubernetes/scripts/create-secrets.sh
```

It refuses, before it touches the cluster, if either credential is missing (naming which, and
nothing else) or malformed. A value with a line break in it is malformed by definition, and it
is the shape of the failure that cost Phase 1 its first real run: `CLAUDE_CODE_OAUTH_TOKEN`
held 2055 characters across 28 lines -- the whole banner `claude setup-token` prints. Whitespace
and control characters are rejected for the same reason. The message names the variable, the
defect, and the size of what was found, never the value:

```text
[SECRETS] ERROR: CLAUDE_CODE_OAUTH_TOKEN contains a line break, so it cannot be a credential:
2055 characters across 28 lines. `claude setup-token` prints a banner around the token; export
the token alone. (The value is not shown.)
```

The same rule is applied to `GITHUB_TOKEN`, so the two stay consistent (#7 wants it inside the
container as well).

An exported value beats `images/.env.local`, matching `images/agent/scripts/smoke.sh`: a stale
line in the file silently overriding what you just exported would install yesterday's
credential and say nothing about it.

### Confirming them, without printing anything

```sh
./deploy/kubernetes/scripts/create-secrets.sh --verify
```

```text
[SECRETS] sandcastle-github-token: key 'token' present, 40 bytes (value not shown)
[SECRETS] sandcastle-claude-oauth: key 'token' present, 108 bytes (value not shown)
```

It asserts the key names -- read with a `go-template` over `.data`, which prints keys and not
values -- and that the stored value is not empty, whose length it reports so an obviously wrong
one is obvious. `kubectl get secret -o jsonpath='{.data.token}'` prints the credential itself,
base64 or not; do not reach for it.

### Rotating them

Re-run the script with the new value in the environment. It replaces rather than fails, so
rotation and first install are the same command:

```sh
export CLAUDE_CODE_OAUTH_TOKEN=...   # the new one
./deploy/kubernetes/scripts/create-secrets.sh
```

A running Pod keeps the value it started with -- `secretKeyRef` resolves once, at Pod start --
so a rotation takes effect on the next run, and a run already in flight is unaffected. Revoke
the old credential at the provider afterwards; deleting it from the cluster does not.

### Why the value never becomes an argument

`kubectl create secret generic --from-literal=token=$TOKEN` puts the credential in `kubectl`'s
argv, where any user on the machine can read it out of the process table, and in the shell
history of whoever ran it. That is precisely the defect #2 lost a review round to, with a token
in `curl`'s `--header`; a reviewer confirmed it live by polling the process table.

So the value goes into a `0600` file inside a `0700` directory that is removed however the
script exits, `kubectl create --dry-run=client` reads *that file*, and the rendered Secret
reaches `kubectl apply` on **stdin**. Only the file's path is ever an argument. The
`--dry-run`-and-apply pipeline is also what makes the script idempotent: `kubectl create` alone
fails with `AlreadyExists` the second time.

That property is asserted, not asserted-about: `images/agent/bootstrap/test/secrets.bats` runs
the script against the recording `kubectl` that `helpers.bash` binds on `PATH` at load time --
so no test can reach a cluster -- and that fake records what reached argv separately from what
reached stdin. The suite refutes distinct canary values in the argv record, and separately
*requires* each one in the store the fake builds from what `apply` was piped, because a
refutation alone would be satisfied by a script that passed no credential at all. One more test
invokes the same fake with `--from-literal` and requires the canary to appear in the argv
record, which is what proves the record is not simply empty. Switching the script to
`--from-literal` fails three of those tests; gutting the fake's argv recording fails the proof
test.

Those tests live in the image's bats suite rather than beside `validate.sh` because that is
where the recording-fake machinery and the assertion helpers already are (`installFakeDocker`,
`installFakeAgentClis`); the suite's own bash-3.2 style guard reaches them there and would not
reach a second suite. They mount the repository root when run in the container, for which see
`images/agent/README.md`.

### Running Codex instead of Claude

Two lines in `job.yaml`, edited together: `AGENT` becomes `codex`, and the
`CLAUDE_CODE_OAUTH_TOKEN` entry becomes `CODEX_API_KEY` or `CODEX_ACCESS_TOKEN`, pointing at a
Secret of its own -- a third entry in `create-secrets.sh`'s `SECRET_SPECS`, which is the whole
change that end needs. §36 asks for one agent, so there is no Codex Secret until someone runs
Codex. `AGENT` is deliberately not a placeholder for exactly this
reason: an agent and its credential have to change together, and a renderer that let you set
`AGENT=codex` against the Claude Secret would produce a Job that starts and then cannot
authenticate.

`OPENAI_API_KEY` is not a third option. Codex `0.154.0` does not read it -- a run with only
that variable set sends no credential at all (#3) -- so wiring it would look like
authentication and be none. `images/agent/README.md` ("Agent credentials") has the full table
of what each CLI accepts and how far each row has been taken.

## Why only one namespace

§21 names two: `sandcastle-agents` for runs and `sandcastle-system` for the server, the UI and
Postgres. Only the first is here, because §36 is explicit that Phase 2 has no server -- there
is nothing to put in `sandcastle-system`, and an empty namespace is not a security boundary,
only a note that someone intends one. It arrives in Phase 3 with the workload it separates.

The boundary that does exist today is the one that matters now: the agent is untrusted code
(§50), so it gets its own namespace, its own identity, and no way to reach the Kubernetes API.

`namespace.yaml` also carries the Pod Security Admission labels, which make the §50 posture the
namespace's rule rather than one Job's good intentions: `restricted` rejects a Pod that is not
`runAsNonRoot`, that allows privilege escalation, that keeps any capability, or that sets no
seccomp profile. Confirmed on the cluster -- a privileged Pod is refused outright:

```text
Error from server (Forbidden): pods "psa-probe" is forbidden: violates PodSecurity
"restricted:latest": privileged (container "c" must not set securityContext.privileged=true), …
```

Note that a *Job* which violates the standard is still accepted, with a warning: admission
runs against the Pod, which the Job controller then fails to create. The warning appears on
`kubectl apply`, and the refusal appears in `kubectl -n sandcastle-agents describe job`.

## Writable paths

The container runs with `readOnlyRootFilesystem: true`, so anything that must be written needs
a volume. Three paths do, and no others:

| Path | Volume | Why |
| --- | --- | --- |
| `/workspace` | `emptyDir` | the checkout and the issue context (§24); it does not need to outlive the run |
| `/home/node` | `emptyDir` | `$HOME`: the agent CLIs and npm write config and cache here |
| `/tmp` | `emptyDir` | temporary files for the CLIs and for anything the repository's own tooling runs |

How that set was established, rather than guessed:

- The published image was run locally with `--read-only` and only `/workspace` writable. The
  whole Phase 1 bootstrap still succeeded -- clone, branch, issue fetch, agent invocation --
  so the bootstrap itself needs nothing else. The agent CLIs are a different matter: `codex
  --version` printed `WARNING: proceeding, even though we could not create PATH aliases:
  Read-only file system (os error 30)`. With `$HOME` writable the warning disappears and
  `$HOME/.codex/tmp/arg0` appears, which is the file it was failing to write. Phase 1 had
  already established that `$HOME` must stay writable (`images/agent/README.md`, "Security
  notes"); this is the mechanism.
- `/tmp` is the one that fails quietly rather than loudly, which is why it is mounted. With
  `/tmp` read-only, `mktemp` fails outright, but Python's `tempfile` falls through its
  candidate list and writes into the current working directory instead -- which is the checkout
  the agent is editing, and a later phase would commit and push it. That is #14's failure mode
  reached by a different road. The Claude Code binary is also a Bun single-file executable that
  consults `TMPDIR` pervasively and unpacks a `/tmp/bun-node-*` shim when it spawns one.
- The set was then confirmed on the cluster, by running a Job built from `job.yaml` -- same
  image digest, same security context, same volumes, but with the credentials removed and the
  command replaced by a filesystem report. `find / -xdev -type d -writable` inside it returned
  exactly `/home/node`, `/tmp`, `/workspace`; `/` was mounted `ro`; the process was uid 1000;
  each `emptyDir` arrived as mode 0777, so uid 1000 can write to it with no `fsGroup`; and
  `/var/run/secrets/kubernetes.io` did not exist, which is `automountServiceAccountToken:
  false` doing its job. The probe Job and the namespace were deleted afterwards.

The image ships an empty `/home/node`, so mounting an `emptyDir` over it hides nothing.

## Decisions worth their own paragraph

**`ttlSecondsAfterFinished: 86400`.** §47's development policy is an hour for a successful Job
and a day for a failed one, and a Job has one TTL, so this is the longer of the two. In Phase 2
the Pod is the only record a run leaves: there is no server, no database, and no log collection
(§48 arrives with Phase 3). Reaping a failure after an hour destroys the only evidence of it,
while keeping a success for a day costs one terminated Pod. Split the pair into the two numbers
§47 asks for once something outside the cluster is keeping the logs.

**`backoffLimit: 0`.** An agent run is not idempotent -- it clones, branches and edits, and in
later phases pushes and comments. Kubernetes' default of 6 would do all of that up to seven
times for one issue.

**The image is pinned by digest.** `:latest` moves on every merge to `main`, so a tag would
make "the same Job" mean a different image tomorrow (§20). To update the pin, read the digest
for the commit you want -- `images/agent/README.md`, "Getting the current digest", explains why
to read it from the `sha-<short-sha>` tag rather than from `latest` -- and replace the `image:`
line in `job.yaml`. `validate.sh` fails if it is ever a tag again.

**No NetworkPolicy.** §51 says to start permissive enough to prove the system and then tighten
deliberately. A follow-up issue does it once a run has actually succeeded.

**No RBAC for the agent.** The ServiceAccount has no Role and no RoleBinding, and the Pod
mounts no token, so the agent cannot reach the Kubernetes API at all (§50). The permissions
§22 describes belong to the Sand Castle server, which creates and watches these Jobs from
outside the namespace -- `server-serviceaccount.yaml`, `server-role.yaml` and
`server-rolebinding.yaml` are that RBAC (#54); "The server's identity" above has the detail.

### Never an empty credential

#14 cost this repository a real bug: an empty `CLAUDE_CONFIG_DIR` made the Claude CLI resolve
its config directory relative to the working directory and write `backups/`, `projects/` and
`sessions/` into the checkout the agent was editing, which Phase 6 would then commit and push.
A Pod spec offers three ways to reproduce it exactly, and the third is the quiet one:

- an `env:` entry with an empty `value:`;
- a `secretKeyRef` with `optional: true` pointing at a key that does not exist;
- an `env:` entry with a name and *neither* `value:` nor `valueFrom:`, which the API server
  accepts and which Kubernetes materialises as the empty string.

All three materialise a variable the CLI reads back as set. The third is the one to keep in
mind while making the Codex edit above by hand, because it looks like an unfinished line rather
than a mistake.

So: run context arrives as plain values, credentials arrive only by required `secretKeyRef`,
and `validate.sh` asserts all four halves of that -- every entry supplies a value, no empty
literal value, no optional secret reference, nothing credential-shaped carrying a literal
value.

## Validating without a cluster

CI cannot reach the cluster, so the manifests are checked statically and that check is a job of
its own (`.github/workflows/kubernetes-manifests.yml`).

```sh
./deploy/kubernetes/scripts/validate.sh      # kubeconform, then the property assertions
./deploy/kubernetes/scripts/prove-checks.sh  # break each property; require validate.sh to notice
```

Both need `kubeconform` and `yq` (`brew install kubeconform yq`; CI installs pinned release
binaries). `validate.sh` renders `job.yaml` with a fixed sample run context, schema-validates
every manifest with `kubeconform -strict`, and then asserts the properties a schema cannot see:
the image is a digest and not a tag, `backoffLimit` is 0, the TTL is §47's 24 hours, the §50
security context is present and set as it should be, `automountServiceAccountToken` is false on
both the Pod and the ServiceAccount, the resource limits are §23's, the writable paths are
mounted and are `emptyDir`s, the `nodeSelector` is the capability one, and no `env:` entry
carries a literal credential value.

The server's RBAC gets its own set: `server-role.yaml` is a `Role` and `server-rolebinding.yaml`
a `RoleBinding`, never their cluster-scoped counterparts; both live in `sandcastle-agents` and
nowhere else; the binding's one subject is `sandcastle-server`, of kind `ServiceAccount`, in
that same namespace; each of the Role's four rules grants exactly the API group, resource and
verb set §22 and "The server's identity" above say it should, checked rule by rule rather than
as a set so that `create` on `jobs` -- what Phase 3 actually calls -- is asserted separately from
the rest; no rule grants a wildcard verb, resource or API group; and `pods/exec` is granted
nowhere. `test("^\*$")` is the wildcard check's actual expression, not `. == "*"`: `yq` treats
an unescaped `*` in `==` as a glob that matches every string, which would make that assertion
pass by matching everything rather than by finding nothing -- the anchored regex is what asks
whether an element is *literally* a single asterisk.

The `nodeSelector` gets two assertions rather than one, and the second is about a *type*: the
value must be the string `"true"`, because a label value is a string and an unquoted `true` is a
YAML boolean the API server refuses. Its mutation has to write the boolean itself -- `yq`'s
`style=""` re-quotes a string whose text would otherwise parse as one, so unquoting cannot be
expressed as a style change the way it can for the run-ID placeholders.

Some of those assertions are only as good as the shape of the thing they read, so the shape is
asserted too. An assertion about `containers[0]` says nothing about a sidecar; an exhaustive
list of `env:` entries says nothing about an `envFrom:`, an `initContainer` or a second
container; and every one of them reads document 0 of its file, so a second document appended
behind the Job would be schema-checked and then never looked at again. `validate.sh` therefore
pins the shape as well as the contents: exactly one container, no init or ephemeral containers,
no `envFrom`, one document per manifest, one Pod per run (`parallelism`/`completions`), and a
manifest set that is exactly the six files named above -- so a seventh manifest is a decision
someone has to make here rather than a file nothing reads. The server's Role gets the same
treatment for its own rule count: exactly four, so a rule added without updating this README and
the table in "The server's identity" fails until someone decides it belongs.

A security context is also defined by what is *absent* from it, and an enumeration of dangerous
fields is out of date the next time Kubernetes adds one. Three of them are asserted by name,
because they are the ones a reader auditing this list will look for and because a named
assertion survives a later relaxation of the pins below: no container of any kind is
`privileged`, no capability is added back after `drop: [ALL]`, and the Pod shares none of the
host's namespaces (`hostNetwork`, `hostPID`, `hostIPC`). Everything else is covered by pinning
key sets -- the container's security context, the Pod's security context, the Pod spec, the Job
spec, and the Pod template's metadata are each exactly the fields they are, and anything else
fails until someone decides it belongs. That one line covers `procMount: Unmasked`, an
`appArmorProfile` or `seLinuxOptions` override, a container-level `runAsUser: 0` quietly
overriding the Pod's 1000, unsafe `sysctls`, a `nodeName` that skips the scheduler, a
`podFailurePolicy` that would make `backoffLimit: 0` mean nothing, and the deprecated-but-still
honoured `container.apparmor.security.beta.kubernetes.io/agent: unconfined` annotation, which
is an AppArmor override that never touches a security context at all.

`privileged` is worth the paragraph it gets in `validate.sh`. Before it was asserted, the
posture held only by coincidence: `privileged: true` alongside `allowPrivilegeEscalation:
false` is refused by the API server's own contradiction rule (*"cannot set
`allowPrivilegeEscalation` to false and `privileged` to true"*), and `privileged: true` with
that field removed is **accepted** by the API server and caught only by the separate assertion
on the field that was removed. Two other rules lining up is not the same as being checked.

Three details are load-bearing. `-strict` is what catches a *misspelled* field:
`readOnlyRootFileSystem` (capital S) is silently ignored by the API server, and by a non-strict
check, and would leave the root filesystem writable while looking correct. The schema step
asserts kubeconform's summary as well as its exit status, because kubeconform exits 0 having
validated nothing when it skips a file whose extension it does not recognise -- which is what
the first draft of this script did to the rendered Job. And the template is rendered a *second*
time with a run ID shaped like a number (`0755`), because every placeholder substitutes text
into YAML that may read it as something else: unquoted, that run ID renders as an integer and
the API server refuses the Job outright (`cannot unmarshal number into Go struct field
ObjectMeta.metadata.labels of type string`). The assertions on that rendering are about types,
not values. Every placeholder in `job.yaml` is quoted for this reason, uniformly, including the
ones that happen to be safe today.

Assertions are plain commands and helper functions that return explicitly, never a bare
`[[ ]]`, so they bite under the bash 3.2 macOS ships as well as under bash 5 -- the house rule
`images/agent/bootstrap/test/style.bats` enforces for the bats suite. These live in a script
rather than in that suite because they are about `deploy/`, not about the image: adding a
second bats suite would mean a second copy of the suite's bootstrapping and a style guard that
does not reach it, for assertions that need neither.

`create-secrets.sh`, `launch-run.sh` and `probe-nodes.sh` are the exception, and for the same
reason rather than against it: what has to be checked about them is a *behaviour* -- what they
put in argv, what they refuse, which failure they name, what they conclude from a container's
exit code -- which needs a recording fake and the assertion helpers the bats suite already has,
not a `yq` expression over a file. So all three are `shellcheck`ed by the `manifests` job here
and exercised by `images/agent/bootstrap/test/secrets.bats`, `launch.bats` and `probe.bats`
under the `test` job, where a fake `kubectl` bound at `helpers.bash` load time means no test can
reach a cluster.

`probe.bats` is about one property: the probe only ever says what it measured. Its fixtures are
the Pod statuses the real cluster reported for `red` (`Succeeded`, exit 0, `2.1.236 (Claude
Code)`) and for `nova` (`Failed`, exit 132, no output at all), plus the `ErrImagePull` message
from a copy of these manifests with the digest zeroed. The tests that matter are the ones about
what it does *not* claim: a node whose image never arrived keeps its label and the run exits
non-zero, and a node that could not be annotated with the image it was measured against is
reported as untrustworthy rather than left quietly labelled `true`.

`launch.bats` drives that fake with output **recorded from the real cluster**: each failure mode
was induced there with fake values and the resulting Pod status, Job condition or event was
copied into the test as a fixture. So the taxonomy is checked against what Kubernetes says
rather than against what the launcher's author assumed it says, and the fake stays a stand-in
for `kubectl` rather than a second implementation of the launcher -- it decides which canned
answer a query wants from the jsonpath, and knows nothing about failure modes.

Every assertion there was proven to bite the way `prove-checks.sh` proves these: one behaviour
was broken at a time -- each branch of the image-pull classifier, the `CreateContainerConfigError`
branch, the deadline check in each of the two places it has to be, the `OOMKilled`, `StartError`
and `Evicted` branches, each preflight check, the admission checks, the agent's exit code, the
log relay, and three separate ways of leaking a credential -- and the suite re-run. Each
mutation was caught, by the test it should have been caught by.

The launcher needs no new assertion in `validate.sh`: what it relies on in `job.yaml` -- an
`AGENT` entry with a literal value, an `image:` pinned to a digest, a `nodeSelector` naming the
capability label -- is already pinned there, by the assertion that the entries carrying a
literal `value:` are exactly `AGENT`, `GITHUB_ISSUE_NUMBER`, `GITHUB_REPOSITORY` and
`SANDCASTLE_RUN_ID`, by the digest pattern, and by the two `nodeSelector` assertions.
`probe-nodes.sh` reads the same two fields out of `job.yaml` with the same `awk` the launcher
uses, rather than `yq`: an operator probing their cluster should need nothing installed beyond
`kubectl`, and `yq` is a validation-time dependency.

`prove-checks.sh` is the other half of the house rule. It copies the manifests, breaks exactly
one property, runs `validate.sh` against the copy and requires it to fail, once per property,
and reports which assertion caught each one so that a mutation failing for an unrelated reason
is visible. It starts with an unmutated control run, because nothing is proven by a mutation
failing if validation fails anyway. A mutation is normally a `yq` expression; one that begins
with `---` is a literal YAML document appended to the manifest instead, which is the only way
to express the two mistakes `yq` cannot make for us -- a second document smuggled into an
existing file, and a whole new manifest appearing in the directory.

Adding an assertion means adding its mutation. An assertion with no mutation behind it is a
line nobody has checked, which is the state #8 found 49 of.

### Checking the jsonpath queries

The launcher decides which layer broke by asking the cluster for twenty-one field paths, in six
`kubectl -o jsonpath` queries, and matching on what comes back. **A field path that is not there
is answered with an empty string and exit 0.** No error, no warning, nothing in a log: the
launcher reads the empty answer as a Pod that reported nothing and falls through to the generic
"could not classify" branch, which is the exact failure §36 exists to prevent, arrived at
confidently. `probe-nodes.sh` reads the cluster the same way, in four more queries.

That used to be invisible in both directions. The bats suite's fake `kubectl` picked its canned
answer from a *substring* of the query, so mutating `state.waiting.reason` to `reasonX` and
`terminated.exitCode` to `exitCodeX` left the whole suite green under both shells while the same
two typos live would have demoted every image-pull and every agent failure to one shrug (#28).
Two checks now stand behind the queries, and they are not the same check:

```sh
make -C images/agent test                            # offline, in CI: the fake refuses a query it was never taught
./deploy/kubernetes/scripts/check-jsonpath.sh        # needs a cluster: every field path against its schema
./deploy/kubernetes/scripts/check-jsonpath.sh --list # what the second one would check, without a cluster
```

**The offline half** is `helpers.bash`: the fake holds every query the two scripts make, written
out whole, and matches on the whole query. A mistyped field path is then a query the fake does
not recognise, which it refuses instead of answering. `launch.bats` extracts every
`-o jsonpath=` from `launch-run.sh` and `probe-nodes.sh` and requires each to appear there
verbatim, so the failure is one named line -- *"asks for a jsonpath the fake kubectl does not
know"* -- rather than an unrelated test failing three steps later for no stated reason. That
also makes adding a query loud: a new one fails the suite until the fake is taught it, which is
one line.

**What the offline half cannot do is notice that Kubernetes changed.** The fake agrees with the
queries because the same hand wrote both; all it can prove is that nobody has since changed one
of them. So `check-jsonpath.sh` asks something that is not us. It pulls every jsonpath out of
the two scripts, reduces each to the field paths it names -- dropping the subscripts, the
literal separators, the `items` of a list, and the key half of an annotation lookup -- and runs
`kubectl explain` on each against the live schema. A field a Kubernetes upgrade renamed or
removed fails there and nowhere else. It needs a cluster, so it is not a CI check and is not
required to be one: run it after upgrading the cluster, and when a query changes. `--list` needs
no cluster and prints the twenty-three field paths it would check, which is also the quickest
way to see that a query says what its author meant.

Both were proven by breaking what they guard, the way `prove-checks.sh` proves `validate.sh`.
`state.terminated.exitCode` in `launch-run.sh` was mutated to `exitCodeX`: on `main` that left
all 46 of `launch.bats`'s tests passing, and with the strict fake it fails 28 of 47, the first
of them naming the query. Against the k3s cluster, that typo and a second one inside a filter
(`conditions[?(@.typeX=="PodScheduled")]`) were both reported by `check-jsonpath.sh`:

```text
[JSONPATH] NOT IN THE SCHEMA: pod.status.conditions.typeX
[JSONPATH] NOT IN THE SCHEMA: pod.status.containerStatuses.state.terminated.exitCodeX
[JSONPATH] 2 of 25 field paths are not in this cluster's schema
```

Reverting both made the suite and the schema check clean again. Adding a query was proven the
same way: a `{.status.hostIP}` the fake had never been taught failed the suite on that one test,
by name, and was removed.

### What these checks do not cover

**Message drift, deliberately.** Every branch of the launcher's classifier matches *prose*: the
kubelet's reasons (`ErrImagePull`, `CreateContainerConfigError`) and containerd's sentences
(`no match for platform`, `failed to authorize`). No schema describes either, so
`check-jsonpath.sh` cannot see them and neither can the fake. A Kubernetes or containerd upgrade
that rewords one demotes that run to the catch-all underneath it -- or, if a *reason* changed,
past the classifier entirely and into the start timeout.

This is an accepted risk rather than an oversight, and it is written here so the two are
distinguishable. Catching a rewording needs a contract test that induces each failure on a live
cluster -- an unpullable digest, an arm64-only image, a misspelled Secret key, a 1000-CPU
request, a one-second deadline, one per branch -- which is what #21 did once, by hand, and
keeping it as a standing check means a cluster, a maintained set of deliberate breakages, and
somebody to read the result. What it buys is a more specific `Fix:` line: the layer is still
named in most cases, and what Kubernetes said is quoted verbatim underneath it either way. That
trade is not worth making today. It changes if the taxonomy ever grows a branch whose
misclassification would send an operator somewhere actively wrong, rather than somewhere vague.

Two smaller gaps, for the same reason: neither check knows whether a field the schema *has* holds
what the launcher assumes it holds -- `state.terminated.signal` exists on every cluster and
containerd fills in none of it, which is why the launcher reads the exit code as well and says
which reading it used -- and `check-jsonpath.sh` validates against whichever cluster you point it
at, so it says the queries fit *that* one and not that they fit the next version of it.

**Both extractors still only parse one spelling of `-o jsonpath=`.** They match literally
rather than parse shell, deliberately, since these are two known files rather than arbitrary
scripts (`check-jsonpath.sh:89-107`). A query written some other way -- double-quoted, unquoted,
built from a variable -- is still not itself understood. What changed is that this no longer
happens silently (#41): a script with five recognised queries and one that is not used to still
look, and pass, like one with five. Both extractors now count every occurrence of
`-o jsonpath=` a script's non-comment lines carry -- not merely whether a line has one, so two
on the same line cannot hide one behind the other -- and require that count to equal how many
they could actually parse, so a spelling neither understands fails loudly -- the bats suite or
`check-jsonpath.sh`, naming the line -- at the point it is introduced, instead of being quietly
left out of both. A comment that happens to mention the flag does not count as an occurrence on
either side, the same way `check-jsonpath.sh`'s own literal matching already skipped a comment
line entirely, so a stray mention in prose cannot fail either check.

### Against the real cluster

A server dry-run is the useful extra that CI cannot run. It needs the namespace to exist,
because the API server resolves a namespaced object's namespace before admitting it:

```sh
kubectl apply -f deploy/kubernetes/namespace.yaml
kubectl apply --dry-run=server -f deploy/kubernetes/serviceaccount.yaml
kubectl apply --dry-run=server -f deploy/kubernetes/server-serviceaccount.yaml
kubectl apply --dry-run=server -f deploy/kubernetes/server-role.yaml
kubectl apply --dry-run=server -f deploy/kubernetes/server-rolebinding.yaml
./deploy/kubernetes/scripts/render-job.sh dry-run-0001 octocat/Hello-World 1 |
  kubectl apply --dry-run=server -f -
```

`create-secrets.sh` has no dry run, because the thing worth checking about it is what actually
lands in the cluster. It was confirmed against the k3s cluster with obviously-fake values: run,
re-run with different values, `--verify` -- two Secrets, one key each, replaced rather than
duplicated, lengths tracking the value -- and then both Secrets and the namespace deleted. The
live half of the argv property was confirmed there too, the way #2's leak was: polling the
process table while the script ran found nothing, while the same poller watching a
`--from-literal` invocation found the value immediately.

`launch-run.sh` has no dry run either, and for a sharper reason: what it is for is the part a
dry run does not have, which is a Pod that either starts or does not. It was exercised against
the k3s cluster with obviously-fake Secret values, which is enough to prove everything except an
agent that authenticates -- the Pod starts, runs as uid 1000 under the §50 context, follows its
logs live, and fails at the clone with a fake token, which the launcher reports as the agent
layer with the container's own exit code. Each cluster-layer failure was then induced in turn,
against a copy of `deploy/kubernetes/` with exactly one thing broken in it: a zeroed digest, an
arm64-only image, a GHCR package that does not exist, a misspelled `key:`, a 1000-CPU request, a
`cpu` request above its own limit, a one-second `activeDeadlineSeconds`, `runAsNonRoot: false`,
a 4Mi memory limit, and -- against the cluster itself -- a deleted ServiceAccount, a deleted
Secret and an unreachable `KUBECONFIG`. Everything created was deleted afterwards.

`probe-nodes.sh` has no dry run for the same reason `create-secrets.sh` does not: what is worth
checking is what actually happens on the node. It was run against the k3s cluster and reported
`red` capable (`exit 0, 2.1.236 (Claude Code)`) and `nova` not (`exit 132 (SIGILL)`), labelling
each and recording the digest beside it; both probe Pods were removed by the script itself. The
three surrounding cases were induced there too: a rendered Job applied with neither node
labelled stayed `Pending` with `0/2 nodes are available: 2 node(s) didn't match Pod's node
affinity/selector`; a Pod carrying the same `nodeSelector` and no `nodeName` was scheduled onto
`red` and onto `red` only; a copy of these manifests with the digest zeroed produced
`NOT MEASURED`, left `nova`'s label exactly as it was and exited non-zero; and a node annotated
with a different digest made the launcher refuse at the capability layer before applying
anything. Everything created was deleted afterwards, and the node labels were removed, so the
probe below is not optional.

The **acceptance run belongs to the repo owner**, like Phase 1's smoke test, because it is the
half that needs real credentials:

```sh
export GITHUB_TOKEN=...              # scoped to the one repository the run works in
export CLAUDE_CODE_OAUTH_TOKEN=...   # from `claude setup-token`; the token, not the banner
kubectl apply -f deploy/kubernetes/namespace.yaml
kubectl apply -f deploy/kubernetes/serviceaccount.yaml
./deploy/kubernetes/scripts/create-secrets.sh
./deploy/kubernetes/scripts/probe-nodes.sh         # nothing schedules until this has run
./deploy/kubernetes/scripts/launch-run.sh <owner/repo> <issue-number>
```

§36 is proven when that exits 0 having cloned the repository, read the issue and changed files
in the workspace. A second run against an issue number that does not exist is the other half:
it must exit non-zero and say `FAILED at the agent layer`, which is the run's own failure and
not the cluster's.

### Making the check required

The `manifests` job is not one of `main`'s required status checks until a repo owner adds it,
the same class of one-time manual step as making the GHCR package public (`images/agent/README.md`).
Repository settings -> Branches -> `main` -> Require status checks -> add `manifests`.

Note that the checks a protected branch requires must run on *every* pull request: GitHub
treats a required check that a `paths:` filter skipped as still pending and blocks the merge
forever. That is why neither this workflow nor `agent-image.yml` filters its `pull_request`
trigger by path.
