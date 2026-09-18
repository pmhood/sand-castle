#!/usr/bin/env bats
# deploy/kubernetes/scripts/probe-nodes.sh: which nodes can actually run the agent binary (#30).
#
# The property worth a suite is that this script only ever says what it measured. A label here
# is the reason job.yaml will or will not schedule a run onto a node, so the ways it can be
# wrong are the ways #30 happens again: claiming a node works when the binary died there,
# claiming it works when nothing ran at all, or claiming it works for an image other than the
# one the run will execute.
#
# The Pod statuses below were recorded from the real k3s cluster, one node at a time, by running
# this probe against `red` (Core i7-6700, AVX2) and `nova` (Core 2 Duo P8800, no AVX2) and
# reading back what Kubernetes reported. helpers.bash binds the recording `kubectl` at load
# time, so nothing here reaches a cluster.
#
# One convention, learned twice here at the cost of an assertion that could not fail: a fragment
# passed to assertContains/assertLineContains is a *substring* test, so every fragment carries
# enough punctuation to exclude the messages it would otherwise also match. A node is `red:` and
# not `red`, because `red` matches the word "measured"; a verdict is `: CAPABLE` and not
# `CAPABLE`, because `CAPABLE` matches "NOT CAPABLE"; a label is `true --` and not `true`,
# because `true` matches the line reporting a label measured against another image.

bats_require_minimum_version 1.5.0

load helpers

REPO_ROOT="$(cd "$(dirname "$BOOTSTRAP_DIR")/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/deploy/kubernetes/scripts/probe-nodes.sh"
JOB_MANIFEST="$REPO_ROOT/deploy/kubernetes/job.yaml"

readonly CAPABILITY_LABEL='sandcastle.dev/agent-capable'
readonly IMAGE_ANNOTATION='sandcastle.dev/agent-capable-image'

# `{phase}|{waiting.reason}|{terminated.exitCode}|{waiting.message}`, the shape probe-nodes.sh
# asks `kubectl get pod` for.
#
# Verbatim, from `red`: the binary ran and exited 0.
readonly FACTS_CAPABLE='Succeeded||0|'
# Verbatim, from `nova`: 132 is 128+4, SIGILL. The container logs nothing at all -- the "Illegal
# instruction (core dumped)" line #30 reported comes from a shell, and there is no shell here.
readonly FACTS_SIGILL='Failed||132|'
# Verbatim, from a copy of deploy/kubernetes with the digest zeroed: the image never arrived, so
# the binary never ran and nothing about the node was measured.
readonly FACTS_NO_IMAGE='Pending|ErrImagePull||rpc error: code = NotFound desc = failed to pull and unpack image "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": failed to resolve reference "ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000": ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000: not found'
# Verbatim: what `claude --version` printed on the node that could run it.
readonly VERSION_LINE='2.1.236 (Claude Code)'

setup() {
    # Short enough that the one test which has to reach the timeout takes about two seconds.
    export SANDCASTLE_PROBE_TIMEOUT=2
    export SANDCASTLE_POLL_INTERVAL=1

    STATE="$KUBECTL_RECORD/state"
    IMAGE=$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")
    state nodeNames 'nova
red'
}

state() {
    printf '%s' "$2" >"$STATE/$1"
}

# What `kubectl get pod` and `kubectl logs` report for one node's probe Pod.
givenNode() {
    state "podFacts.sandcastle-probe-$1" "$2"
    state "logs.sandcastle-probe-$1" "${3-}"
}

# What the cluster already says about a node: the label, and the image it was measured against.
givenLabelled() {
    state "nodeCapability.$1" "$2|${3-}"
}

recorded() {
    cat "$STATE/$1" 2>/dev/null || true
}

appliedManifest() {
    cat "$KUBECTL_RECORD/stdin" 2>/dev/null || true
}

# That a Pod was deleted at all proves nothing: probe-nodes.sh also deletes the Pod *before*
# applying it, because one left by an interrupted probe would otherwise be read as this run's
# result. So this requires a delete that came after *that Pod's own* apply.
#
# "After an apply" is not enough either, and the difference is the whole reason this comment is
# long. An earlier version of this helper kept one `applied` flag for the run: it flipped on the
# first apply of any Pod, so once `nova` had been applied, `red`'s *pre-apply* sweep satisfied
# `red`'s assertion -- and removing the cleanup for `red` alone left this file entirely green
# with a Pod leaked on the node. The flag has to be per-Pod, which is what the fake's `pod-events`
# log makes possible: one ordered line per applied or deleted Pod, by name.
#
# The lesson is not that the first version was careless. It is that whether an assertion can fail
# depends on the state of everything around it, and the only way to know is to break the
# behaviour and watch it fail -- for each case, not for the first one.
assertDeletedAfterApply() {
    local pod=$1 line applied=no events="$KUBECTL_RECORD/state/pod-events"

    [ -f "$events" ] || {
        printf 'no Pod was ever applied or deleted, so %s cannot have been cleaned up\n' "$pod"
        return 1
    }
    while IFS= read -r line; do
        case $line in
            "applied $pod") applied=yes ;;
            "deleted $pod")
                [ "$applied" = no ] || return 0
                ;;
        esac
    done <"$events"
    printf 'no delete of %s after its own apply, in:\n%s\n' "$pod" "$(cat "$events")"
    return 1
}

@test "the script and the manifest this suite cross-checks are both present" {
    [ -x "$PROBE_SCRIPT" ]
    [ -f "$JOB_MANIFEST" ]
}

# --- what the probe concludes ---------------------------------------------------------------

@test "a node that runs the binary is labelled capable, and the version it printed is reported" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"

    run "$PROBE_SCRIPT" red
    [ "$status" -eq 0 ]
    assertLineContains "$output" 'red:' ': CAPABLE' "$VERSION_LINE"

    run recorded labels
    assertContains "$output" "red $CAPABILITY_LABEL=true"
}

@test "a node where the binary dies is labelled not capable, and SIGILL is named" {
    givenNode nova "$FACTS_SIGILL"

    run "$PROBE_SCRIPT" nova
    [ "$status" -eq 0 ]
    # The exit code alone is the measurement; naming SIGILL is what keeps an operator from
    # reading 132 as an agent bug, which is the mistake #30 is about.
    assertLineContains "$output" 'nova:' 'NOT CAPABLE' '132' 'SIGILL'

    run recorded labels
    assertContains "$output" "nova $CAPABILITY_LABEL=false"
    refuteContains "$output" "nova $CAPABILITY_LABEL=true"
}

@test "both nodes at once are told apart, and the summary counts them" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    givenNode nova "$FACTS_SIGILL"

    run "$PROBE_SCRIPT"
    [ "$status" -eq 0 ]
    assertLineContains "$output" '1 capable, 1 not capable, 0 not measured'

    run recorded labels
    assertContains "$output" "red $CAPABILITY_LABEL=true" "nova $CAPABILITY_LABEL=false"
}

# The honest half, and the reason this is a measurement rather than a claim. An image that never
# arrived says nothing about whether the node could have executed it.
@test "a node the probe could not measure keeps its label, and the run says so" {
    givenNode nova "$FACTS_NO_IMAGE"

    run "$PROBE_SCRIPT" nova
    [ "$status" -eq 1 ]
    assertLineContains "$output" 'nova:' 'NOT MEASURED' 'could not be pulled'
    assertContains "$output" 'left exactly as it was'

    # Neither verdict was written: not `false`, which would be a claim about a binary that never
    # ran, and not `true`.
    [ ! -f "$STATE/labels" ]
    [ ! -f "$STATE/annotations" ]
}

# --- what the probe actually runs -------------------------------------------------------------

@test "the probe runs job.yaml's image and job.yaml's agent, not a copy of either" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    run "$PROBE_SCRIPT" red
    [ "$status" -eq 0 ]

    local agent
    agent=$(awk '$1 == "-" && $2 == "name:" { n = $3; next } n == "AGENT" && $1 == "value:" { gsub(/"/, "", $2); print $2; exit }' "$JOB_MANIFEST")
    assertMatches "$IMAGE" '^ghcr\.io/pmhood/sandcastle-agent@sha256:[0-9a-f]{64}$'
    [ "$agent" = claude ]

    run appliedManifest
    assertContains "$output" "image: $IMAGE" "command: [\"$agent\", \"--version\"]" 'nodeName: red'
}

# nodeName, not a nodeSelector: the probe has to be able to measure a node that job.yaml's own
# selector excludes, which before the first probe is every node.
@test "the probe reaches its node directly rather than through the scheduler" {
    givenNode nova "$FACTS_SIGILL"
    run "$PROBE_SCRIPT" nova
    [ "$status" -eq 0 ]

    run appliedManifest
    assertContains "$output" 'nodeName: nova'
    refuteContains "$output" 'nodeSelector'
}

@test "the probe Pod carries no credential and references no Secret" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    run "$PROBE_SCRIPT" red
    [ "$status" -eq 0 ]

    # `--version` needs neither Secret the run reads, and a Pod that mounted them would be
    # handing a credential to a node that may not be able to run anything (§15, §52).
    run appliedManifest
    refuteContains "$output" 'secretKeyRef' 'sandcastle-github-token' 'sandcastle-claude-oauth' 'TOKEN'
    assertContains "$output" 'automountServiceAccountToken: false'
}

@test "the probe Pod is deleted whichever way it ended" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    givenNode nova "$FACTS_SIGILL"

    run "$PROBE_SCRIPT"
    [ "$status" -eq 0 ]

    assertDeletedAfterApply sandcastle-probe-red
    assertDeletedAfterApply sandcastle-probe-nova
}

# The measurement is over as soon as the container has an exit code, and the Pod goes whether or
# not there was one: a node whose image never arrived is the case most likely to leave one
# behind, and it is in a namespace whose TTL cleanup (§47) only reaps Jobs.
@test "the probe Pod is deleted when nothing could be measured either" {
    givenNode nova "$FACTS_NO_IMAGE"

    run "$PROBE_SCRIPT" nova
    [ "$status" -eq 1 ]
    assertDeletedAfterApply sandcastle-probe-nova
}

# --- the label is about one image ------------------------------------------------------------

@test "a labelled node records the image it was measured against" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    run "$PROBE_SCRIPT" red
    [ "$status" -eq 0 ]

    run recorded annotations
    assertContains "$output" "red $IMAGE_ANNOTATION=$IMAGE"
}

# The label goes on first, so a failure to record the image leaves a node claiming `true` beside
# the *previous* image -- which launch-run.sh refuses. The other order would leave this image
# beside the previous verdict, which reads as verified and is not.
@test "a node that cannot be annotated is reported as untrustworthy rather than left quietly labelled" {
    givenNode red "$FACTS_CAPABLE" "$VERSION_LINE"
    export KUBECTL_FAKE_ANNOTATE_FAILS=yes

    run "$PROBE_SCRIPT" red
    [ "$status" -eq 1 ]
    assertContains "$output" 'cannot be trusted'
}

# --- reading the answer back -------------------------------------------------------------------

@test "--show reports all four states and changes nothing" {
    givenLabelled red true "$IMAGE"
    givenLabelled nova false "$IMAGE"

    run "$PROBE_SCRIPT" --show
    [ "$status" -eq 0 ]
    assertLineContains "$output" 'red:' 'true --' "job.yaml's image"
    assertLineContains "$output" 'nova:' 'false --' 'died here'

    [ ! -f "$STATE/labels" ]
    [ ! -f "$STATE/annotations" ]
    [ ! -f "$STATE/applied-pods" ]
}

@test "--show calls a node measured against another image what it is, not capable" {
    givenLabelled red true 'ghcr.io/pmhood/sandcastle-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000'
    givenLabelled nova '' ''

    run "$PROBE_SCRIPT" --show
    [ "$status" -eq 0 ]
    assertLineContains "$output" 'red:' 'measured against'
    assertLineContains "$output" 'nova:' 'never probed'
    # The label says true and the answer is still "nothing can run", which is the whole point of
    # recording what was measured.
    assertContains "$output" 'no run can be launched'
}

@test "probe-nodes.sh is valid bash syntax" {
    bash -n "$PROBE_SCRIPT"
}
