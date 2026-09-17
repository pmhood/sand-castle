# Kubernetes manifests for an agent run

Phase 2 (docs/ARCHITECTURE.md §36): the Phase 1 container, run as a Kubernetes Job, by hand,
with no Sand Castle server involved. See §19 (Job, not Pod), §20 (the example Job), §21
(namespace), §23 (resource limits), §24 (workspace), §47 (cleanup) and §50 (security
boundaries).

```text
deploy/kubernetes/
├── namespace.yaml        the sandcastle-agents namespace every run lives in (§21)
├── serviceaccount.yaml   the run's identity, with no Kubernetes API token (§50)
├── job.yaml              one run, as a Job template with three placeholders (§19, §20)
└── scripts/
    ├── create-secrets.sh the two credential Secrets the Job reads (§14, §15)
    ├── render-job.sh     substitutes the placeholders; the only renderer
    ├── validate.sh       kubeconform + property assertions; what CI runs
    └── prove-checks.sh   breaks each property and requires validate.sh to notice
```

No Helm chart, no Kustomize overlays, no templating engine. §36 is one Job run by hand and §54
is explicit that the CRD is not to be built first; the same restraint applies to packaging.
The launcher (#21) will render the same template from the same script.

## Running one

In apply order -- the Job controller refuses to create a Pod whose ServiceAccount or Secret is
missing, and says so only in the Job's events:

```sh
kubectl apply -f deploy/kubernetes/namespace.yaml
kubectl apply -f deploy/kubernetes/serviceaccount.yaml
./deploy/kubernetes/scripts/create-secrets.sh                # see "Credentials" below
./deploy/kubernetes/scripts/render-job.sh <run-id> <owner/repo> <issue-number> | kubectl apply -f -
```

Then watch it, by the label §20 asks for:

```sh
kubectl -n sandcastle-agents logs -f -l sandcastle.run=<run-id>
kubectl -n sandcastle-agents get job -l sandcastle.run=<run-id>
```

`render-job.sh` validates what it substitutes -- the run ID must be a DNS-1123 label short
enough to prefix, the repository must be `owner/repo`, the issue must be a positive integer --
and refuses an empty value rather than rendering `sandcastle-` and a Job that collides with the
next one.

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

An exported value beats `images/.env.local`, which is where this script differs from `smoke.sh`
deliberately: it writes to a cluster, and a stale line in the file silently overriding what you
just exported would install yesterday's credential and say nothing about it.

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
outside the namespace; they arrive with the server in Phase 3.

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
mounted and are `emptyDir`s, and no `env:` entry carries a literal credential value.

Some of those assertions are only as good as the shape of the thing they read, so the shape is
asserted too. An assertion about `containers[0]` says nothing about a sidecar; an exhaustive
list of `env:` entries says nothing about an `envFrom:`, an `initContainer` or a second
container; and every one of them reads document 0 of its file, so a second document appended
behind the Job would be schema-checked and then never looked at again. `validate.sh` therefore
pins the shape as well as the contents: exactly one container, no init or ephemeral containers,
no `envFrom`, one document per manifest, one Pod per run (`parallelism`/`completions`), and a
manifest set that is exactly the three files named above -- so a fourth manifest is a decision
someone has to make here rather than a file nothing reads.

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

`create-secrets.sh` is the exception, and for the same reason rather than against it: what has
to be checked about it is a *behaviour* -- what it puts in argv, what it refuses -- which needs
a recording fake and the assertion helpers the bats suite already has, not a `yq` expression
over a file. So it is `shellcheck`ed by the `manifests` job here and exercised by
`images/agent/bootstrap/test/secrets.bats` under the `test` job, where a fake `kubectl` bound at
`helpers.bash` load time means no test can reach a cluster.

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

### Against the real cluster

A server dry-run is the useful extra that CI cannot run. It needs the namespace to exist,
because the API server resolves a namespaced object's namespace before admitting it:

```sh
kubectl apply -f deploy/kubernetes/namespace.yaml
kubectl apply --dry-run=server -f deploy/kubernetes/serviceaccount.yaml
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

### Making the check required

The `manifests` job is not one of `main`'s required status checks until a repo owner adds it,
the same class of one-time manual step as making the GHCR package public (`images/agent/README.md`).
Repository settings -> Branches -> `main` -> Require status checks -> add `manifests`.

Note that the checks a protected branch requires must run on *every* pull request: GitHub
treats a required check that a `paths:` filter skipped as still pending and blocks the merge
forever. That is why neither this workflow nor `agent-image.yml` filters its `pull_request`
trigger by path.
