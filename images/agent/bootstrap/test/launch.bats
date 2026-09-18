#!/usr/bin/env bats
# deploy/kubernetes/scripts/launch-run.sh: one agent run, as a Kubernetes Job
# (docs/ARCHITECTURE.md §36, §31, §47).
#
# Two properties are worth a suite. The first is the one #2 established for every script in this
# repository: no credential in argv, in what is applied, or in what is printed. The second is
# the one §36 is actually for -- a run that does not produce a result has to say *which layer*
# broke, because a Pod that never starts looks identical whether the image is unpullable, a
# Secret key is misspelled, the node is the wrong architecture, or admission refused the Pod.
#
# The strings the launcher matches on are not invented here. Almost every fixture below was
# recorded from a real k3s cluster by inducing that failure with obviously fake values -- a
# zeroed digest, an arm64-only image, a misspelled `key:`, a 1000-CPU request, a one-second
# deadline, a `runAsNonRoot: false` -- and reading back what Kubernetes said. helpers.bash binds
# the recording `kubectl` at load time, so nothing here can reach a cluster.
#
# "Almost", and the exceptions are marked, because a fixture that claims to be a recording and
# is not is the kind of thing the next person builds on. Three kinds appear below and each says
# which it is: verbatim, recorded-and-transposed (the cluster's exact wording, with the probe's
# object names replaced by this suite's run ID and the real image and Secret names), and
# constructed (the field shape is the cluster's, the value was never read back, because that
# failure could not be induced here).

bats_require_minimum_version 1.5.0

load helpers

REPO_ROOT="$(cd "$(dirname "$BOOTSTRAP_DIR")/../.." && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/deploy/kubernetes/scripts/launch-run.sh"
SECRETS_SCRIPT="$REPO_ROOT/deploy/kubernetes/scripts/create-secrets.sh"
JOB_MANIFEST="$REPO_ROOT/deploy/kubernetes/job.yaml"

# Obviously-fake credentials, distinct per variable. They are seeded into the fake cluster the
# way an operator seeds the real one, and then must appear nowhere the launcher goes.
readonly CANARY_GITHUB='canary-github-launch-6a1c8e'
readonly CANARY_OAUTH='canary-oauth-launch-2d7b40'

readonly RUN_ID='run-test-0001'
readonly JOB_NAME="sandcastle-$RUN_ID"
readonly POD_NAME="$JOB_NAME-abcde"

# What `kubectl get pod` reports, in the order and with the separator launch-run.sh asks for:
# phase|status.reason|waiting.reason|running.startedAt|terminated.reason|terminated.exitCode|
# terminated.signal|spec.nodeName|message
#
# The last two fields are #31's. They are empty in every fixture recorded before the launcher
# asked for them, which is what an unread field looks like rather than what that Pod carried: a
# terminated Pod always has a `spec.nodeName`. The signal-death fixtures further down were
# recorded after, and carry both.
#
# Verbatim.
readonly FACTS_PULLING='Pending||ContainerCreating||||||'
readonly FACTS_AGENT_FAILED='Failed||||Error|3|||'
readonly FACTS_OOM='Failed||||OOMKilled|137|||'
readonly FACTS_START_ERROR='Failed||||StartError|128|||failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: "/no/such/binary": stat /no/such/binary: no such file or directory'
readonly FACTS_UNSCHEDULED='Pending||||||||'

# Constructed. A container that is running reports `running.startedAt` and nothing else, but the
# timestamp is a plausible one rather than a read-back value.
readonly FACTS_RUNNING='Running|||2026-09-17T02:14:41Z|||||'
# Constructed: no run on this cluster has succeeded, because succeeding needs a real credential.
# That run is the repo owner's acceptance test (deploy/kubernetes/README.md).
readonly FACTS_SUCCEEDED='Succeeded||||Completed|0|||'
# Constructed: eviction needs a node under real resource pressure, which was not worth producing
# on someone's cluster. `status.reason` and `status.message` are where the kubelet puts it.
readonly FACTS_EVICTED='Failed|Evicted|||||||The node was low on resource: ephemeral-storage.'

# Verbatim.
readonly FACTS_IMAGE_MISSING='Pending||ErrImagePull||||||rpc error: code = NotFound desc = failed to pull and unpack image "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": failed to resolve reference "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000: not found'
# Verbatim. The architecture mismatch also ends in "not found", which is why its own test exists.
readonly FACTS_WRONG_ARCH='Pending||ErrImagePull||||||rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/arm64v8/alpine:3.20": no match for platform in manifest: not found'
# Recorded and transposed: the probe pulled ghcr.io/pmhood/sandcastle-no-such-package, and the
# package name is replaced throughout -- including inside the token URL's scope -- by the one
# whose privacy would actually cause this (#18's GHCR package is meant to be public).
readonly FACTS_REGISTRY_DENIED='Pending||ErrImagePull||||||failed to pull and unpack image "ghcr.io/pmhood/sandcastle-agent:latest": failed to resolve reference "ghcr.io/pmhood/sandcastle-agent:latest": failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Apmhood%2Fsandcastle-agent%3Apull&service=ghcr.io: 403 Forbidden'
# Verbatim: this one was induced through the launcher itself, against the real Secret.
readonly FACTS_BAD_SECRET_KEY='Pending||CreateContainerConfigError||||||couldn'"'"'t find key tokenn in Secret sandcastle-agents/sandcastle-github-token'
# Recorded and transposed: the probe deleted sandcastle-github-token; the other Secret is named
# here so the two credentials-layer fixtures are not both about the same one.
readonly FACTS_SECRET_MISSING='Pending||CreateContainerConfigError||||||secret "sandcastle-claude-oauth" not found'

# The signal deaths (#31). Every one of these was read back from a Pod on the k3s cluster, and
# the first is the run the issue was filed for.
#
# Verbatim, from the repo owner's own failed Phase 2 run -- job sandcastle-run-20260918-003624-fa2cba,
# still in the namespace, which died on `nova` because the agent binary needs AVX2 and that CPU
# does not have it (#30). Note what is *not* in it: `terminated.signal` is empty and
# `terminated.reason` is the same `Error` an ordinary failure carries. The container was not
# itself signalled -- its PID 1 is the bootstrap, a shell, and the shell propagated the 132 its
# `claude` child died with, which is the shape every signal death takes in this image.
readonly FACTS_SIGILL='Failed||||Error|132||nova|'
# Verbatim, induced on `red` by a container whose child really was killed by that signal
# (`node -e 'process.kill(process.pid, "SIG...")'`), so PID 1 propagated 128+n exactly as the
# owner's run did. Four signals, one recording each, because they share a branch and the branch
# has to be shown naming each of them.
readonly FACTS_SIGSEGV='Failed||||Error|139||red|'
readonly FACTS_SIGABRT='Failed||||Error|134||red|'
readonly FACTS_SIGBUS='Failed||||Error|135||red|'
readonly FACTS_SIGFPE='Failed||||Error|136||red|'
# Verbatim, the same way. `reason` is `Error` and not `OOMKilled`: this is what a SIGKILL that
# the kubelet did not attribute to memory looks like, and it is why the OOM branch above cannot
# be the whole answer for 137.
readonly FACTS_SIGKILL='Failed||||Error|137||red|'
# Verbatim, from a container that ran `exit 132` of its own accord on `red`. It is identical to
# FACTS_SIGILL but for the node name, which is the point: on this runtime the API cannot tell
# the two apart, so the launcher says which evidence it read rather than pretending it can.
readonly FACTS_EXIT_132_BY_CHOICE='Failed||||Error|132||red|'
# Constructed, and the only fixture here that is: no runtime on this cluster fills in
# `state.terminated.signal`. That was not assumed -- a container's own PID 1 was killed by SIGILL
# on `nova` and reported `reason: Error, exitCode: 132` and no signal, field for field the same
# as `exit 132`. The field is Kubernetes API v1 and other runtimes do set it, and where it is
# set it is the authority: this one says signal 11 beside an exit code of 132, so a launcher
# that read the number would answer SIGILL and one that reads what Kubernetes reported answers
# SIGSEGV.
readonly FACTS_REPORTED_SIGNAL_DISAGREES='Failed||||Error|132|11|red|'

# `{PodScheduled.reason}|{PodScheduled.message}`. Both verbatim -- including the scheduled case,
# which carries *no* reason and no message: the condition is `status: "True"` and nothing else,
# so the whole answer is the separator. It was `True|` here until a review read the live
# condition; both are `!= Unschedulable` so nothing behaved differently, which is exactly why a
# wrong fixture survives.
readonly SCHEDULING_UNSCHEDULABLE='Unschedulable|0/2 nodes are available: 2 Insufficient cpu. no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.'
# Verbatim, recorded by applying a rendered Job to the cluster with neither node labelled: this
# is what job.yaml's capability selector (#30) looks like from the scheduler, and the sentence
# is the same one a taint or a mislabelled node would produce. Nothing in it names the label.
readonly SCHEDULING_NO_CAPABLE_NODE="Unschedulable|0/2 nodes are available: 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling."
readonly SCHEDULING_OK='|'

# Verbatim. A Job reaches FailureTarget first and Failed a moment later, with the same reason.
readonly CONDITIONS_DEADLINE='FailureTarget DeadlineExceeded Job was active longer than specified deadline
Failed DeadlineExceeded Job was active longer than specified deadline'
readonly CONDITIONS_BACKOFF='Failed BackoffLimitExceeded Job has reached the specified backoff limit'

# Recorded and transposed: the probes' Pod names become this suite's, and the probe's
# `nonexistent-sa` becomes the real ServiceAccount. EVENT_PSA keeps two of the five violations
# the cluster listed, because the launcher matches the prefix and the rest is repetition.
readonly EVENT_PSA='Error creating: pods "sandcastle-run-test-0001-x9k2p" is forbidden: violates PodSecurity "restricted:latest": privileged (container "agent" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "agent" must set securityContext.allowPrivilegeEscalation=false)'
readonly EVENT_NO_SERVICE_ACCOUNT='Error creating: pods "sandcastle-run-test-0001-" is forbidden: error looking up service account sandcastle-agents/sandcastle-agent: serviceaccount "sandcastle-agent" not found'
# Verbatim, from `kubectl apply`'s stderr.
readonly WARNING_PSA='Warning: would violate PodSecurity "restricted:latest": runAsNonRoot != true (pod must not set securityContext.runAsNonRoot=false)'

setup() {
    # The operator's real images/.env.local must stay unreachable from any test: create-secrets.sh
    # reads it, and the launcher runs create-secrets.sh.
    export SANDCASTLE_ENV_FILE="$BATS_TEST_TMPDIR/env.local"

    # Short enough that a test which has to reach a timeout takes about two seconds, long enough
    # that the poll loop runs more than once.
    export SANDCASTLE_START_TIMEOUT=2
    export SANDCASTLE_FINISH_TIMEOUT=2
    export SANDCASTLE_POLL_INTERVAL=1

    export RUN_ID
    STATE="$KUBECTL_RECORD/state"
    seedSecrets
    seedCapableNode
}

# A cluster with one node that can run job.yaml's image, which is what every test below except
# the capability ones assumes: job.yaml schedules onto nothing else (#30), and the launcher
# refuses to apply a Job no node can take. The image is read from the manifest rather than
# written out here, so the two cannot drift.
seedCapableNode() {
    state capableNodes "red|$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")"
}

# Puts the two Secrets in the fake cluster the way an operator does, then forgets that it
# happened: every assertion about argv below is about what *the launcher* passed.
seedSecrets() {
    GITHUB_TOKEN=$CANARY_GITHUB CLAUDE_CODE_OAUTH_TOKEN=$CANARY_OAUTH \
        "$SECRETS_SCRIPT" >/dev/null 2>&1
    rm -f "$KUBECTL_RECORD/argv" "$KUBECTL_RECORD/commands" "$KUBECTL_RECORD/stdin"
}

state() {
    printf '%s' "$2" >"$STATE/$1"
}

# A Pod that exists and is in the state the test describes.
givenPod() {
    state podName "$POD_NAME"
    state podFacts "$1"
    state schedulingFacts "${2:-$SCHEDULING_OK}"
}

# Runs the launcher as an operator does, with the credentials they happen to have exported:
# the leak this suite is looking for is the launcher putting one of them somewhere.
runLaunch() {
    run env GITHUB_TOKEN="$CANARY_GITHUB" CLAUDE_CODE_OAUTH_TOKEN="$CANARY_OAUTH" \
        "$LAUNCH_SCRIPT" "$@"
}

recordedArgv() {
    cat "$KUBECTL_RECORD/argv" "$KUBECTL_RECORD/commands" 2>/dev/null || true
}

appliedManifest() {
    cat "$KUBECTL_RECORD/stdin" 2>/dev/null || true
}

@test "the script and the manifest this suite cross-checks are both present" {
    # A wrong volume mount is how this file silently stops testing anything; failing here says
    # so, where a missing-file error inside a `run` would read as a script bug.
    [ -x "$LAUNCH_SCRIPT" ]
    [ -f "$JOB_MANIFEST" ]
}

# --- what reaches the cluster -------------------------------------------------------------

@test "a successful run exits 0, relays the Pod's logs, and says where the Job went" {
    givenPod "$FACTS_SUCCEEDED"
    state logs '[SANDCASTLE] Run run-test-0001 started
[GIT] Cloning octo/demo from https://github.com
[CLAUDE] Starting Claude Code CLI'

    runLaunch octo/demo 7
    [ "$status" -eq 0 ]
    # The run's own output is relayed verbatim, §31 prefixes and all.
    assertContains "$output" '[GIT] Cloning octo/demo' '[CLAUDE] Starting Claude Code CLI'
    assertLineContains "$output" 'PASSED' 'exited 0'
    assertContains "$output" "kubectl -n sandcastle-agents delete job $JOB_NAME"
}

@test "the manifest applied carries this run's ID and job.yaml's digest-pinned image" {
    givenPod "$FACTS_SUCCEEDED"
    runLaunch octo/demo 7
    [ "$status" -eq 0 ]

    local digest
    digest=$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")
    assertMatches "$digest" '^ghcr\.io/pmhood/sandcastle-agent@sha256:[0-9a-f]{64}$'

    run appliedManifest
    assertContains "$output" \
        "name: \"$JOB_NAME\"" \
        "sandcastle.run: \"$RUN_ID\"" \
        "value: \"octo/demo\"" \
        "value: \"7\"" \
        "$digest"
    # Nothing was left unsubstituted; render-job.sh's own guard, seen from the far side.
    refuteContains "$output" '${RUN_ID}' '${GITHUB_REPOSITORY}' '${GITHUB_ISSUE_NUMBER}'
}

@test "no credential value reaches argv, the applied manifest, or the launcher's output" {
    givenPod "$FACTS_SUCCEEDED"
    runLaunch octo/demo 7
    [ "$status" -eq 0 ]

    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"
    run recordedArgv
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"
    run appliedManifest
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"
    # The Pod gets them by reference, which is the only way it may (§15, §52).
    assertContains "$output" 'secretKeyRef' 'name: sandcastle-github-token' 'name: sandcastle-claude-oauth'
}

# The check on the checks above. Three refutations of the same two values would all pass against
# records that were simply empty -- the shape of mistake #8 found 49 of -- so this requires the
# records to hold what the launcher demonstrably did put there.
@test "the argv and manifest records are real: the run ID and the image are in them" {
    givenPod "$FACTS_SUCCEEDED"
    runLaunch octo/demo 7
    [ "$status" -eq 0 ]

    run recordedArgv
    assertContains "$output" "$RUN_ID" 'sandcastle-agents'
    run appliedManifest
    assertContains "$output" "$RUN_ID" 'ghcr.io/pmhood/sandcastle-agent@sha256:'
}

# --- failing before anything is applied ----------------------------------------------------

@test "a missing Secret stops the run before a Job is applied, and names the credential layer" {
    rm -rf "$KUBECTL_RECORD/store/sandcastle-claude-oauth"
    givenPod "$FACTS_SUCCEEDED"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the credentials layer'
    assertContains "$output" 'create-secrets.sh'
    [ ! -f "$STATE/applied-job" ]
}

@test "a Secret holding the wrong key is caught before a Job is applied" {
    mv "$KUBECTL_RECORD/store/sandcastle-claude-oauth/token" \
        "$KUBECTL_RECORD/store/sandcastle-claude-oauth/tokenn"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the credentials layer'
    [ ! -f "$STATE/applied-job" ]
}

@test "a missing namespace names namespace.yaml and applies nothing" {
    export KUBECTL_FAKE_NAMESPACE_MISSING=yes
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer' 'namespace sandcastle-agents does not exist'
    assertContains "$output" 'namespace.yaml'
    [ ! -f "$STATE/applied-job" ]
}

@test "a missing ServiceAccount names serviceaccount.yaml and applies nothing" {
    export KUBECTL_FAKE_SERVICEACCOUNT_MISSING=yes
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer' 'ServiceAccount sandcastle-agent'
    assertContains "$output" 'serviceaccount.yaml'
    [ ! -f "$STATE/applied-job" ]
}

# #30: job.yaml schedules onto a node only if a probe measured that the agent binary runs there.
# On a cluster nobody has probed that is every node, so the run would sit Pending until the
# start timeout reading "didn't match Pod's node affinity/selector" -- true, and no help.
@test "a cluster where no node has been probed is refused before a Job is applied" {
    state capableNodes ''

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the capability layer' 'sandcastle.dev/agent-capable=true'
    assertContains "$output" 'probe-nodes.sh'
    [ ! -f "$STATE/applied-job" ]
}

# The half a nodeSelector cannot state. A label records that one *image* ran on that node, and
# job.yaml's digest moves; the selector matches the label, not the reason for it.
@test "a node measured against another image is refused, and named" {
    state capableNodes 'red|ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000'

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the capability layer' ': red' 'claim about another image'
    assertContains "$output" 'sandcastle.dev/agent-capable-image' 'probe-nodes.sh'
    # Both capability messages name the annotation, so naming it proves nothing on its own; this
    # is the message for a node that was measured, once, for something else.
    refuteContains "$output" 'no recorded image'
    [ ! -f "$STATE/applied-job" ]
}

# A label with nothing recorded beside it is what a hand-applied one looks like -- an operator's
# claim that no probe stands behind, which is the thing #30 rejected in favour of a measurement.
# It is refused like a stale one, and says so in its own words: the fix is the same, but what the
# operator will find when they look is not.
@test "a capability label with no recorded image is named as never measured, not as stale" {
    state capableNodes 'red|'

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the capability layer' ': red' 'no recorded image'
    assertContains "$output" 'applied by hand'
    # The stale message describes a different situation and would send the operator looking for
    # an annotation that is not there.
    refuteContains "$output" 'is a claim about another image'
    [ ! -f "$STATE/applied-job" ]
}

# Every candidate node has to agree, not merely one of them: the scheduler chooses among all the
# nodes the selector matches, so a cluster where one is current and one is stale is the coin flip
# #30 is about, with an extra step.
@test "one current node does not excuse a stale one" {
    state capableNodes "red|$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")
nova|ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the capability layer' ': nova' 'claim about another image'
    # The current node is not named as a problem, and is not what the message is about.
    refuteContains "$output" ': red'
    [ ! -f "$STATE/applied-job" ]
}

# Listing nodes is cluster-scoped and everything else the launcher does is not, so a kubeconfig
# that may not look is absence of evidence rather than evidence of trouble: say so and carry on,
# leaving the scheduler to enforce the selector it always did.
@test "a node list this kubeconfig may not read is a warning, not a refusal" {
    export KUBECTL_FAKE_NODES_UNREADABLE=yes
    givenPod "$FACTS_SUCCEEDED"

    runLaunch octo/demo 7
    [ "$status" -eq 0 ]
    assertLineContains "$output" 'Cannot read the cluster' 'sandcastle.dev/agent-capable'
    refuteContains "$output" 'FAILED at the capability layer'
}

@test "a run ID already in the cluster is refused rather than applied over" {
    printf 'yes' >"$STATE/job-exists"
    runLaunch octo/demo 7
    [ "$status" -eq 64 ]
    assertContains "$output" "$JOB_NAME already exists"
    [ ! -f "$STATE/applied-job" ]
}

@test "a repository that is not owner/repo fails before the cluster is touched" {
    runLaunch not-a-repo 7
    [ "$status" -eq 64 ]
    # render-job.sh's message, not a second copy of its rules.
    assertLineContains "$output" '[RENDER]' 'is not owner/repo'
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

@test "an agent job.yaml does not run is refused, and says the two change together" {
    runLaunch octo/demo 7 codex
    [ "$status" -eq 64 ]
    assertContains "$output" "job.yaml runs 'claude', not 'codex'" 'README.md'
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

# --- the failure taxonomy ------------------------------------------------------------------

@test "an unpullable digest is named as the image layer, not as an agent failure" {
    givenPod "$FACTS_IMAGE_MISSING"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the image layer' 'registry has no such image'
    assertContains "$output" 'digest'
    refuteContains "$output" 'agent layer'
}

# The one that looks least like what it is: the digest is right and the registry is right.
@test "an image with no build for the node's architecture is named as such" {
    givenPod "$FACTS_WRONG_ARCH"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the image layer' "architecture"
    # It must not be mistaken for the missing-digest case, whose message it also matches.
    refuteContains "$output" 'registry has no such image'
}

@test "a registry that refuses the pull is distinguished from one that has no such image" {
    givenPod "$FACTS_REGISTRY_DENIED"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the image layer' 'registry refused the pull'
    assertContains "$output" 'private'
    refuteContains "$output" 'registry has no such image'
}

@test "a misspelled Secret key is named by the message, not left to kubectl describe" {
    givenPod "$FACTS_BAD_SECRET_KEY"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the credentials layer'
    # The operator is told which key, without having to go and look.
    assertContains "$output" "couldn't find key tokenn in Secret sandcastle-agents/sandcastle-github-token"
}

@test "a Secret that disappeared after preflight is still named at the credentials layer" {
    givenPod "$FACTS_SECRET_MISSING"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the credentials layer'
    assertContains "$output" 'secret "sandcastle-claude-oauth" not found'
}

@test "a Pod no node can take is the scheduling layer, and says so while it waits" {
    givenPod "$FACTS_UNSCHEDULED" "$SCHEDULING_UNSCHEDULABLE"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'not scheduled yet' 'Insufficient cpu'
    assertLineContains "$output" 'FAILED at the scheduling layer'
    assertContains "$output" 'Insufficient cpu'
}

# The preflight above cannot see every way this happens -- a label removed while the run was
# being applied, a node that went away -- so the scheduler's own refusal has to name the
# capability label too. The message it quotes is the same sentence for a taint and for a
# mislabelled node, and an operator who reads only it learns nothing to do.
@test "a Pod no node matches names the capability label and the probe, not just Pending" {
    givenPod "$FACTS_UNSCHEDULED" "$SCHEDULING_NO_CAPABLE_NODE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'not scheduled yet' "didn't match Pod's node affinity/selector"
    assertLineContains "$output" 'sandcastle.dev/agent-capable=true' 'probe-nodes.sh'
    assertLineContains "$output" 'FAILED at the scheduling layer'
}

# The other unschedulable case keeps the answer it had: capacity is not a capability problem,
# and telling an operator to re-probe their nodes over a CPU request would be worse than saying
# nothing.
@test "a Pod no node has room for is still about capacity, not about the probe" {
    givenPod "$FACTS_UNSCHEDULED" "$SCHEDULING_UNSCHEDULABLE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the scheduling layer' 'no node could take the Pod'
    assertContains "$output" 'free capacity'
    refuteContains "$output" 'probe-nodes.sh'
}

@test "a Job admission will refuse is named at apply time, not after the start timeout" {
    state applyWarning "$WARNING_PSA"
    givenPod "$FACTS_SUCCEEDED"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the admission layer'
    assertContains "$output" 'PodSecurity' 'restricted'
}

@test "a Pod admission refused with no warning is named from the Job's own event" {
    state podName ''
    state jobCreateFailure "$EVENT_PSA"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the admission layer'
    assertContains "$output" 'violates PodSecurity'
}

@test "a ServiceAccount deleted between preflight and the Pod is named from the event" {
    state podName ''
    state jobCreateFailure "$EVENT_NO_SERVICE_ACCOUNT"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer' 'ServiceAccount does not exist'
    assertContains "$output" 'serviceaccount.yaml'
}

# activeDeadlineSeconds deletes the Pod, so this is the one failure that must be read from the
# Job. Before it was, a deadline that expired during scheduling was reported as "the Job created
# no Pod", which is true and useless.
@test "activeDeadlineSeconds is named as a timeout even though the Pod is gone" {
    state podName ''
    state jobConditions "$CONDITIONS_DEADLINE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the timeout layer' 'activeDeadlineSeconds'
}

@test "a deadline that expires after the Pod started is still named as a timeout" {
    givenPod "$FACTS_RUNNING"
    state jobConditions "$CONDITIONS_DEADLINE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    # The container did start, and was followed, before the Job's deadline had the last word.
    assertLineContains "$output" 'Container started at' '2026-09-17T02:14:41Z'
    assertLineContains "$output" 'FAILED at the timeout layer'
}

@test "a container killed for exceeding its memory limit is the runtime layer, not the agent" {
    givenPod "$FACTS_OOM"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'memory limit'
    refuteContains "$output" 'agent layer'
}

@test "a container whose process could not start is the runtime layer, not the agent" {
    givenPod "$FACTS_START_ERROR"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'could not start'
    assertContains "$output" 'no such file or directory'
    refuteContains "$output" 'agent layer'
}

@test "an evicted Pod is the scheduling layer, and says the node was under pressure" {
    givenPod "$FACTS_EVICTED"
    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the scheduling layer' 'evicted'
    assertContains "$output" 'The node was low on resource'
}

# The two "nothing is happening" timeouts. Neither has a Kubernetes reason to quote, which is
# exactly why each has to say which of the two it is and where to look next.
@test "a Job that never produces a Pod times out saying so, and points at the Job" {
    state podName ''

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer' 'created no Pod within 2s'
    assertContains "$output" "describe job $JOB_NAME"
}

@test "a container stuck creating times out against the Pod, not the Job" {
    givenPod "$FACTS_PULLING"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer' 'container did not start within 2s'
    assertContains "$output" "describe pod $POD_NAME" 'ContainerCreating'
}

@test "a Pod that vanished with only a Job condition left is not reported as a success" {
    state podName ''
    state jobConditions "$CONDITIONS_BACKOFF"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the cluster layer'
    assertContains "$output" 'BackoffLimitExceeded'
}

# --- signal deaths (#31) ---------------------------------------------------------------------
#
# A container killed by a signal is not an agent that failed, and the run this repository lost is
# the proof: it cloned, read the issue, started the CLI, and died of SIGILL on a node whose CPU
# cannot run the binary. The launcher called that the agent layer and added that it was "not a
# cluster problem" -- two sentences, both wrong, both confident.
#
# Every fragment below is a substring test, and these messages are close siblings of each other,
# so each test also refutes what the neighbouring branches would have said. Collapsing any two of
# the three branches has to make one of these fail.

@test "the SIGILL that #31 was filed for is the node layer, names nova, and points at the probe" {
    # #31's cluster exactly: a node labelled capable, against this very image, that is not.
    state capableNodes "nova|$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")"
    givenPod "$FACTS_SIGILL"
    state logs '[CLAUDE] Starting Claude Code CLI in /workspace/repo'

    runLaunch octo/demo 7
    # Not 132: a number the kernel chose is not a result the agent returned.
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the node layer' 'SIGILL killed the run on node nova'
    assertContains "$output" 'probe-nodes.sh' 'sandcastle.dev/agent-capable=false'
    # What Kubernetes actually said, under the heading that says so -- and nothing more, because
    # 128+4 is this script's reading and belongs in its own voice.
    assertContains "$output" 'reason Error, exit code 132'
    # The blind spot itself: this run's output cannot explain a binary that never executed.
    refuteContains "$output" 'FAILED at the agent layer'
}

@test "a SIGSEGV is a crash in the run, not a node that cannot execute it" {
    givenPod "$FACTS_SIGSEGV"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGSEGV killed the run on node red'
    assertContains "$output" 'faulted rather than choosing to exit'
    # The SIGILL branch would send an operator to re-probe nodes over a crash that says nothing
    # about the node; the SIGKILL branch would send them looking for a kill that did not happen.
    refuteContains "$output" 'probe-nodes.sh' 'cannot execute this build' 'OOMKilled'
    refuteContains "$output" 'FAILED at the agent layer'
}

@test "a SIGABRT shares the crash branch and still names itself" {
    givenPod "$FACTS_SIGABRT"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGABRT killed the run on node red'
    assertContains "$output" 'faulted rather than choosing to exit'
    refuteContains "$output" 'SIGSEGV' 'probe-nodes.sh'
}

@test "a SIGBUS shares the crash branch and still names itself" {
    givenPod "$FACTS_SIGBUS"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGBUS killed the run on node red'
    assertContains "$output" 'faulted rather than choosing to exit'
    refuteContains "$output" 'SIGSEGV' 'probe-nodes.sh'
}

@test "a SIGFPE shares the crash branch and still names itself" {
    givenPod "$FACTS_SIGFPE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGFPE killed the run on node red'
    assertContains "$output" 'faulted rather than choosing to exit'
    refuteContains "$output" 'SIGSEGV' 'probe-nodes.sh'
}

# 137 keeps the OOM answer it had, which is matched from `reason: OOMKilled` above. This is the
# other 137: a kill the kubelet attributed to nothing, which used to read as an agent failure.
@test "a SIGKILL the kubelet did not call OOM is not an OOM, a crash, or the agent" {
    givenPod "$FACTS_SIGKILL"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGKILL killed the run on node red'
    assertContains "$output" 'did not report it as OOMKilled' 'describe pod'
    # "Raise the memory limit" is the OOM branch's answer and would be a guess here; "it
    # faulted" is the crash branch's and would be wrong -- nothing faults on a SIGKILL.
    refuteContains "$output" 'exceeded its memory limit' 'faulted rather than choosing to exit'
    refuteContains "$output" 'FAILED at the agent layer'
}

@test "a signal Kubernetes reports decides the branch, not an exit code that looks like one" {
    givenPod "$FACTS_REPORTED_SIGNAL_DISAGREES"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    # The exit code is 132, which is 128+4; the reported signal is 11. The report wins.
    assertLineContains "$output" 'FAILED at the runtime layer' 'SIGSEGV killed the run' 'the container reported signal 11'
    assertContains "$output" 'exit code 132, signal 11'
    refuteContains "$output" 'SIGILL' 'FAILED at the node layer' '128+'
}

# The limit of the above, stated rather than hidden. containerd reports no signal at all, so a
# container that chose to `exit 132` and one killed by SIGILL are the same Pod status field for
# field -- the two fixtures differ only in the node name. The launcher reads the convention,
# which is right for every 128+n this image can produce (its PID 1 is a shell), and says in the
# message which evidence that was, so the reading can be disagreed with.
@test "an exit code read as a signal says that is what it did" {
    givenPod "$FACTS_EXIT_132_BY_CHOICE"

    runLaunch octo/demo 7
    [ "$status" -eq 69 ]
    assertLineContains "$output" 'FAILED at the node layer' 'SIGILL killed the run on node red' \
        'exit 132 is 128+4, and no signal was reported'
    refuteContains "$output" 'the container reported signal'
}

# --- the agent's own failure, which is the one the run itself chose --------------------------

@test "an agent that exits non-zero exits with its code and is named as the agent layer" {
    givenPod "$FACTS_AGENT_FAILED"
    state logs '[SANDCASTLE] Clone of octo/demo failed'

    runLaunch octo/demo 7
    # The container's own status, faithfully: not 1, and not the cluster code.
    [ "$status" -eq 3 ]
    assertLineContains "$output" 'FAILED at the agent layer' 'exited 3'
    assertContains "$output" '[SANDCASTLE] Clone of octo/demo failed'
    # Every other failure in this file says which cluster layer broke. This one says the run
    # chose its status -- which is a claim about this exit code, and no longer a claim that the
    # cluster is fine because the container ran (#31).
    assertContains "$output" 'No signal ended it, so the run chose that status'
    refuteContains "$output" 'FAILED at the node layer' 'FAILED at the runtime layer'
}

@test "launch-run.sh is valid bash syntax" {
    bash -n "$LAUNCH_SCRIPT"
}
