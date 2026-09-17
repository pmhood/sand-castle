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
# The strings the launcher matches on are not invented here. Every fixture below was recorded
# from a real k3s cluster by inducing that failure with obviously fake values -- a zeroed digest,
# an arm64-only image, a misspelled `key:`, a 1000-CPU request, a one-second deadline, a
# `runAsNonRoot: false` -- and reading back what Kubernetes said. helpers.bash binds the
# recording `kubectl` at load time, so nothing here can reach a cluster.

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
# phase|status.reason|waiting.reason|running.startedAt|terminated.reason|terminated.exitCode|message
readonly FACTS_PULLING='Pending||ContainerCreating||||'
readonly FACTS_RUNNING='Running|||2026-09-17T02:14:41Z|||'
readonly FACTS_SUCCEEDED='Succeeded||||Completed|0|'
readonly FACTS_AGENT_FAILED='Failed||||Error|3|'
readonly FACTS_OOM='Failed||||OOMKilled|137|'
readonly FACTS_START_ERROR='Failed||||StartError|128|failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: "/no/such/binary": stat /no/such/binary: no such file or directory'
readonly FACTS_EVICTED='Failed|Evicted|||||The node was low on resource: ephemeral-storage.'
readonly FACTS_UNSCHEDULED='Pending||||||'

readonly FACTS_IMAGE_MISSING='Pending||ErrImagePull||||rpc error: code = NotFound desc = failed to pull and unpack image "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": failed to resolve reference "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000: not found'
# The architecture mismatch also ends in "not found", which is why its own test exists.
readonly FACTS_WRONG_ARCH='Pending||ErrImagePull||||rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/arm64v8/alpine:3.20": no match for platform in manifest: not found'
readonly FACTS_REGISTRY_DENIED='Pending||ErrImagePull||||failed to pull and unpack image "ghcr.io/pmhood/sandcastle-agent:latest": failed to resolve reference "ghcr.io/pmhood/sandcastle-agent:latest": failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Apmhood%2Fsandcastle-agent%3Apull&service=ghcr.io: 403 Forbidden'
readonly FACTS_BAD_SECRET_KEY='Pending||CreateContainerConfigError||||couldn'"'"'t find key tokenn in Secret sandcastle-agents/sandcastle-github-token'
readonly FACTS_SECRET_MISSING='Pending||CreateContainerConfigError||||secret "sandcastle-claude-oauth" not found'

readonly SCHEDULING_UNSCHEDULABLE='Unschedulable|0/2 nodes are available: 2 Insufficient cpu. no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.'
readonly SCHEDULING_OK='True|'

readonly CONDITIONS_DEADLINE='FailureTarget DeadlineExceeded Job was active longer than specified deadline
Failed DeadlineExceeded Job was active longer than specified deadline'
readonly CONDITIONS_BACKOFF='Failed BackoffLimitExceeded Job has reached the specified backoff limit'

readonly EVENT_PSA='Error creating: pods "sandcastle-run-test-0001-x9k2p" is forbidden: violates PodSecurity "restricted:latest": privileged (container "agent" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "agent" must set securityContext.allowPrivilegeEscalation=false)'
readonly EVENT_NO_SERVICE_ACCOUNT='Error creating: pods "sandcastle-run-test-0001-" is forbidden: error looking up service account sandcastle-agents/sandcastle-agent: serviceaccount "sandcastle-agent" not found'
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

# --- the agent's own failure, which is the one that is *not* a cluster problem ---------------

@test "an agent that exits non-zero exits with its code and is named as the agent layer" {
    givenPod "$FACTS_AGENT_FAILED"
    state logs '[SANDCASTLE] Clone of octo/demo failed'

    runLaunch octo/demo 7
    # The container's own status, faithfully: not 1, and not the cluster code.
    [ "$status" -eq 3 ]
    assertLineContains "$output" 'FAILED at the agent layer' 'exited 3'
    assertContains "$output" '[SANDCASTLE] Clone of octo/demo failed'
    # Every other failure in this file says which cluster layer broke. This one says it did not.
    assertContains "$output" 'not a cluster problem'
}

@test "launch-run.sh is valid bash syntax" {
    bash -n "$LAUNCH_SCRIPT"
}
