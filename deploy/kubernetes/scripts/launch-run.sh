#!/usr/bin/env bash
# Runs one agent run on the cluster and follows it (docs/ARCHITECTURE.md §36, §31, §47).
#
# This is §36's proof, and the cluster counterpart of images/agent/scripts/smoke.sh: render
# job.yaml for a fresh run ID, apply it, follow the Pod's logs live, and exit with the run's
# result. There is no Sand Castle server here and this is not the beginning of one -- §37 is
# where a server first creates a Job.
#
# Usage:
#   ./deploy/kubernetes/scripts/launch-run.sh <owner/repo> <issue-number> [agent]
#   GITHUB_REPOSITORY=owner/repo GITHUB_ISSUE_NUMBER=7 ./…/launch-run.sh
#
# It takes no credential, by argument or otherwise, and needs none: the run's two credentials
# reach the Pod through the `secretKeyRef` entries job.yaml already carries, resolved by the
# kubelet from Secrets scripts/create-secrets.sh put in the cluster (§15, §52). So there is no
# value here to leak into argv, into the applied manifest, or into a log line -- and what this
# script checks before applying anything is that those Secrets are *present*, not what is in
# them.
#
# The part worth reading is classifyWaiting/reportOutcome below. A run that does not produce a
# result looks the same from outside whatever the reason -- a Pod that never starts is a Pod
# that never starts -- and Phase 1's harness earned its keep by naming the layer instead. Every
# failure mode here was induced on a real k3s cluster and the strings matched are what
# Kubernetes actually said; README.md ("When a run fails") has the table.

set -euo pipefail
# Tracing is off however this was invoked, as in every script here: this one handles no
# credential, but it invokes create-secrets.sh, which does (§14).
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly NAMESPACE="sandcastle-agents"
readonly SERVICE_ACCOUNT="sandcastle-agent"

# job.yaml's nodeSelector, named here because the scheduler's refusal does not name it (#30),
# and the annotation scripts/probe-nodes.sh writes beside it saying which image it measured.
readonly CAPABILITY_LABEL="sandcastle.dev/agent-capable"
readonly CAPABILITY_IMAGE_ANNOTATION="sandcastle.dev/agent-capable-image"
readonly PROBE_SCRIPT="./deploy/kubernetes/scripts/probe-nodes.sh"

# sysexits(3) values, so that a run that never happened is distinguishable from an agent that
# ran and failed: an agent failure exits with the *container's* own status, which is small and
# ordinary. The message is the authority either way; the code is for whatever wraps this.
readonly EXIT_USAGE=64    # EX_USAGE: the arguments are wrong
readonly EXIT_CLUSTER=69  # EX_UNAVAILABLE: the run never ran, or the cluster ended it

# How long to wait before giving up and saying why. It bounds *each* of the two waits that
# precede the logs -- the Job producing a Pod, and that Pod's container starting -- so a run that
# stalls in both spends up to twice it here. One number for both, because neither is a deadline
# on the run itself: that is activeDeadlineSeconds' job (§23). An image pull on a cold node is
# the slow case; scheduling that will never succeed is the case that has to time out rather than
# be guessed at.
readonly START_TIMEOUT="${SANDCASTLE_START_TIMEOUT:-300}"
# How long to wait after the logs end for the Pod's exit status to be reported.
readonly FINISH_TIMEOUT="${SANDCASTLE_FINISH_TIMEOUT:-60}"
readonly POLL_INTERVAL="${SANDCASTLE_POLL_INTERVAL:-2}"

# The separator the jsonpath queries below join their fields with, and that `read` splits them
# back on. Deliberately not a tab: IFS treats repeated *whitespace* as one delimiter, so an
# empty field -- and most of these fields are empty most of the time -- would silently shift
# every later field one place left. A non-whitespace separator keeps empty fields empty. It
# appears only between fields, never inside one, because the free-text message is always last.
readonly FIELD_SEPARATOR='|'

# RUN_ID may arrive from the environment, as in render-job.sh; the rest are this script's own.
RUN_ID=${RUN_ID:-}
JOB_NAME=
POD_NAME=
RENDERED=
JOB_APPLIED=no
SCHEDULING_REPORTED=no

# §31's shape, with this script's own prefix, as scripts/render-job.sh and
# scripts/create-secrets.sh have theirs. The Pod's own output is relayed verbatim on stdout,
# already prefixed by the bootstrap; everything this script says goes to stderr, so the two can
# be separated by whoever runs it.
log() {
    printf '[LAUNCH] %s\n' "$*" >&2
}

usage() {
    cat >&2 <<EOF
Usage: $0 <owner/repo> <issue-number> [agent]

Runs one agent run as a Kubernetes Job in the $NAMESPACE namespace and follows it.

  GITHUB_REPOSITORY, GITHUB_ISSUE_NUMBER and AGENT are read from the environment if set,
  and take precedence over the arguments. RUN_ID overrides the generated run ID.

This script takes no credential and accepts none: the run reads its credentials from the
Secrets deploy/kubernetes/scripts/create-secrets.sh creates.

Exit status: 0 the agent succeeded, $EXIT_USAGE the arguments are wrong, $EXIT_CLUSTER the run never ran
or the cluster ended it, anything else the agent's own exit code.
EOF
}

dieUsage() {
    log "ERROR: $*"
    usage
    exit "$EXIT_USAGE"
}

# The one message an operator reads when something goes wrong, and the reason this script is
# more than three kubectl calls. It names the layer that broke, what to do, and -- last, and
# labelled as such -- what Kubernetes itself said, so that finding out never requires going
# back to `kubectl describe` and reading a Pod spec for a misspelled key.
fail() {
    local layer=$1 summary=$2 fix=$3 detail=${4-} line

    log ""
    log "FAILED at the $layer layer: $summary"
    log "  Fix: $fix"
    if [ -n "$detail" ]; then
        log "  Kubernetes said:"
        while IFS= read -r line; do
            log "    $line"
        done <<<"$detail"
    fi
    reportWhereTheRunIs
    exit "$EXIT_CLUSTER"
}

# A failed Job is kept, by TTL, for §47's 24 hours: in Phase 2 the Pod is the only record a run
# leaves, so every failure path says where that record is and how to remove it early.
reportWhereTheRunIs() {
    # Nothing was applied if this failed in preflight, and pointing an operator at a Job that
    # does not exist is worse than saying nothing.
    [ "$JOB_APPLIED" = yes ] || return 0
    log ""
    log "  Run $RUN_ID is kept until its TTL expires (24h). Until then:"
    log "    kubectl -n $NAMESPACE describe job $JOB_NAME"
    log "    kubectl -n $NAMESPACE logs -l sandcastle.run=$RUN_ID"
    log "    kubectl -n $NAMESPACE delete job $JOB_NAME"
}

# The environment takes precedence over the arguments, as in render-job.sh and smoke.sh.
parseArgs() {
    local arg

    # Wherever it appears, not only first: `launch-run.sh owner/repo --help` is someone asking
    # what the third argument is, and answering it by launching a run called `--help` would be a
    # surprising way to say so.
    for arg in "$@"; do
        case $arg in
            --help | -h)
                usage
                exit 0
                ;;
        esac
    done

    GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-${1-}}
    GITHUB_ISSUE_NUMBER=${GITHUB_ISSUE_NUMBER:-${2-}}
    AGENT=${AGENT:-${3-}}

    [ $# -le 3 ] || dieUsage "too many arguments"
    [ -n "$GITHUB_REPOSITORY" ] || dieUsage "repository not set"
    [ -n "$GITHUB_ISSUE_NUMBER" ] || dieUsage "issue number not set"
}

# A DNS-1123 label, unique per run, and short enough for render-job.sh to prefix. The seconds
# make it sort; the six random hex characters make two runs started in the same second
# distinct. `od` rather than python3, because this script runs where kubectl runs.
generateRunId() {
    local stamp random
    stamp=$(date -u +%Y%m%d-%H%M%S)
    random=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    RUN_ID="run-$stamp-$random"
}

# Rendering first, and locally: a mistyped repository fails here, before anything is asked of
# the cluster. render-job.sh is the only renderer (#19) and validates every value it
# substitutes, so this adds no validation of its own and inherits its messages.
renderJob() {
    RENDERED=$("$SCRIPT_DIR/render-job.sh" "$RUN_ID" "$GITHUB_REPOSITORY" "$GITHUB_ISSUE_NUMBER") ||
        exit "$EXIT_USAGE"
    JOB_NAME="sandcastle-$RUN_ID"
}

# The literal value of one `env:` entry in the manifest that is about to be applied.
manifestEnvValue() {
    printf '%s\n' "$RENDERED" | awk -v want="$1" '
        $1 == "-" && $2 == "name:" { current = $3; next }
        current == want && $1 == "value:" { gsub(/"/, "", $2); print $2; exit }'
}

manifestImage() {
    printf '%s\n' "$RENDERED" | awk '$1 == "image:" { print $2; exit }'
}

# `AGENT` is a constant in job.yaml and not a placeholder, deliberately: an agent and its
# credential have to change together, so a launcher that let you ask for Codex against the
# Claude Secret would hand you a Job that starts and then cannot authenticate (#19). The
# argument is still accepted, because asking for the agent you think you are running is
# reasonable -- it is checked against the manifest rather than substituted into it.
requireAgentMatchesManifest() {
    local manifestAgent
    manifestAgent=$(manifestEnvValue AGENT)
    [ -n "$manifestAgent" ] ||
        fail cluster "job.yaml sets no AGENT, so the Pod would fail its own validation" \
            "restore the AGENT entry in deploy/kubernetes/job.yaml"

    AGENT=${AGENT:-$manifestAgent}
    [ "$AGENT" = "$manifestAgent" ] ||
        dieUsage "job.yaml runs '$manifestAgent', not '$AGENT'. The agent and its credential change together: see deploy/kubernetes/README.md, \"Running Codex instead of Claude\"."
}

# The nodes job.yaml's selector will let this run onto, each with the image scripts/probe-nodes.sh
# measured it against. One line per node, `name|image`, and an unannotated node yields an empty
# second field rather than dropping a line.
capableNodes() {
    kubectl get nodes -l "$CAPABILITY_LABEL=true" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.sandcastle\.dev/agent-capable-image}{"\n"}{end}' 2>&1
}

# The half of #30 that a nodeSelector alone cannot state. The label is a measurement, and what
# it measured was one binary in one image: job.yaml's digest moves, deliberately (§20), and a
# node verified against the previous one is a `true` that is about something else. Nothing in
# Kubernetes notices that -- the selector matches the label, not the reason for it -- so it is
# checked here, before a Job exists, against what probe-nodes.sh recorded.
#
# It is a refusal and not a warning, and the asymmetry is the argument: a stale label costs an
# intermittent SIGILL that presents as an agent bug (this issue, and the sibling one about
# misreading it), and re-probing costs one command and about a minute. A warning would arrive in
# the middle of a launch that then appears to proceed, which is precisely when nobody reads it.
# Every capable node must agree with the manifest, not merely one of them, because the scheduler
# chooses among all of them and "mostly verified" is the coin flip this issue is about.
#
# Not being able to *look* is different from seeing a mismatch, and is not fatal: listing nodes
# is cluster-scoped, and launch-run.sh otherwise needs nothing outside its namespace. Absence of
# evidence leaves the scheduler to enforce the selector and reportScheduling to explain it.
requireNodesVerifiedForThisImage() {
    local image output node nodeImage capable=0 stale='' unrecorded=''

    image=$(manifestImage)
    if ! output=$(capableNodes); then
        log "Cannot read the cluster's nodes, so $CAPABILITY_LABEL is unverified here: ${output%%$'\n'*}"
        log "  The scheduler still enforces job.yaml's nodeSelector; this check only reads it early."
        return 0
    fi

    # Two ways to be wrong, kept apart because they are different mistakes and an operator will
    # find a different thing when they look. A node measured against another image was probed,
    # once, for something else; a node with no image recorded at all was never probed by this
    # script, because the probe always records one -- so that is a label somebody applied by
    # hand, which is the claim #30 replaced with a measurement.
    #
    # Names only, on one line: which image each carries is what `--show` is for, and a message
    # that has to wrap to be read is a message that does not get read.
    while IFS=$FIELD_SEPARATOR read -r node nodeImage; do
        [ -n "$node" ] || continue
        capable=$((capable + 1))
        [ "$nodeImage" != "$image" ] || continue
        if [ -z "$nodeImage" ]; then
            unrecorded="$unrecorded $node"
        else
            stale="$stale $node"
        fi
    done <<<"$output"

    # No `detail` on any of them: `fail` labels that "Kubernetes said", and what follows here is
    # this script's own reading of the cluster rather than anything Kubernetes was asked to judge.
    [ "$capable" -gt 0 ] ||
        fail capability "no node carries $CAPABILITY_LABEL=true, and job.yaml schedules a run onto nothing else" \
            "$PROBE_SCRIPT runs \`$AGENT --version\` on each node and labels what actually happened"

    [ -z "$unrecorded" ] ||
        fail capability "$CAPABILITY_LABEL carries no recorded image on:$unrecorded, so nothing measured it (the probe always writes $CAPABILITY_IMAGE_ANNOTATION beside the label; a label without one was applied by hand)" \
            "$PROBE_SCRIPT measures those nodes by running \`$AGENT --version\` on them"

    [ -z "$stale" ] ||
        fail capability "$CAPABILITY_LABEL is a claim about another image on:$stale (their $CAPABILITY_IMAGE_ANNOTATION is not the digest job.yaml pins)" \
            "$PROBE_SCRIPT re-measures them against the image job.yaml pins now, and $PROBE_SCRIPT --show says which image each node carries"
}

# Everything that can be known before the Job exists. Each check names the file that fixes it,
# because once a Job is applied every one of these looks the same from outside: no Pod.
preflight() {
    local output

    command -v kubectl >/dev/null ||
        fail kubectl "kubectl is not on PATH" "install kubectl and point KUBECONFIG at the cluster"

    # One call answers three questions, and its stderr says which: a cluster that cannot be
    # reached, a kubeconfig that is not allowed to look, and a namespace that is not there are
    # three different problems with the same symptom.
    if ! output=$(kubectl get namespace "$NAMESPACE" 2>&1); then
        case $output in
            *"Unable to connect"* | *"connection refused"* | *"no such host"* | *"i/o timeout"* | *"EOF"*)
                fail cluster "the cluster is not reachable" \
                    "check KUBECONFIG and that the cluster is up" "$output"
                ;;
            *Unauthorized* | *forbidden* | *Forbidden* | *"must be logged in"*)
                fail cluster "this kubeconfig may not read namespace $NAMESPACE" \
                    "use a context with access to $NAMESPACE" "$output"
                ;;
            *)
                fail cluster "namespace $NAMESPACE does not exist" \
                    "kubectl apply -f deploy/kubernetes/namespace.yaml" "$output"
                ;;
        esac
    fi

    kubectl get serviceaccount "$SERVICE_ACCOUNT" --namespace "$NAMESPACE" >/dev/null 2>&1 ||
        fail cluster "ServiceAccount $SERVICE_ACCOUNT does not exist in $NAMESPACE" \
            "kubectl apply -f deploy/kubernetes/serviceaccount.yaml"

    # Before the Job rather than after it, because this is the one refusal the cluster would
    # otherwise express as a Pod that sits Pending for $START_TIMEOUT seconds saying only that
    # no node matched a selector (#30).
    requireNodesVerifiedForThisImage

    # Only reachable with RUN_ID set by hand; a generated one cannot collide. Applying over a
    # live Job would be refused for its immutable fields, and applying over a finished one
    # would silently attach this run's logs to the old Job's.
    if kubectl get job "$JOB_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
        dieUsage "a Job named $JOB_NAME already exists; RUN_ID must be new (or delete it: kubectl -n $NAMESPACE delete job $JOB_NAME)"
    fi

    # The credential layer, checked before the Job exists rather than diagnosed afterwards out
    # of a CreateContainerConfigError. This is create-secrets.sh's own --verify, which reads
    # the key names and the value lengths and prints no value; there is no second opinion about
    # what the Secrets should be called.
    "$SCRIPT_DIR/create-secrets.sh" --verify ||
        fail credentials "the Secrets the Job reads are missing, misnamed, or hold the wrong key" \
            "./deploy/kubernetes/scripts/create-secrets.sh (the [SECRETS] line above says which)"
}

applyJob() {
    local output status=0 line

    log "Applying $JOB_NAME"
    output=$(printf '%s\n' "$RENDERED" | kubectl apply --namespace "$NAMESPACE" -f - 2>&1) || status=$?

    while IFS= read -r line; do
        [ -z "$line" ] || log "  $line"
    done <<<"$output"

    [ "$status" -eq 0 ] ||
        fail cluster "the API server refused the Job" \
            "./deploy/kubernetes/scripts/validate.sh, then fix job.yaml" "$output"
    JOB_APPLIED=yes

    # Pod Security Admission runs against the *Pod*, so a Job that violates it is accepted with
    # this warning and then never produces a Pod. Saying so now costs nothing; waiting for the
    # start timeout to say it costs $START_TIMEOUT seconds.
    case $output in
        *"violate PodSecurity"*)
            fail admission "the Job was accepted but its Pod will be refused by Pod Security Admission" \
                "job.yaml must satisfy the restricted profile namespace.yaml enforces (§50); ./deploy/kubernetes/scripts/validate.sh" \
                "$output"
            ;;
    esac
}

# `[*]` and not `[0]`: an index into a list that exists and is empty is a jsonpath error, and an
# error here would be indistinguishable from an empty answer, which this script reads as "the
# Pod is gone". A wildcard over an absent or empty list is the empty string, cleanly.
podName() {
    kubectl --namespace "$NAMESPACE" get pod -l "sandcastle.run=$RUN_ID" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
}

# Reasons and codes first, messages last: a message may contain anything, including a newline,
# and `read` would then drop whatever came after it. Only one of the three messages is ever
# set, so joining them loses nothing.
#
# The `|` between the fields is $FIELD_SEPARATOR, spelled out because a jsonpath is one fixed
# string and interpolating a shell variable through its quoting would cost more than it saves.
# Both this query and schedulingFacts below have to be changed with the constant if it changes.
podFacts() {
    kubectl --namespace "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}{"|"}{.status.reason}{"|"}{.status.containerStatuses[*].state.waiting.reason}{"|"}{.status.containerStatuses[*].state.running.startedAt}{"|"}{.status.containerStatuses[*].state.terminated.reason}{"|"}{.status.containerStatuses[*].state.terminated.exitCode}{"|"}{.status.containerStatuses[*].state.waiting.message}{.status.containerStatuses[*].state.terminated.message}{.status.message}' 2>/dev/null || true
}

schedulingFacts() {
    kubectl --namespace "$NAMESPACE" get pod "$POD_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}{"|"}{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true
}

jobConditions() {
    kubectl --namespace "$NAMESPACE" get job "$JOB_NAME" \
        -o jsonpath='{range .status.conditions[*]}{.type} {.reason} {.message}{"\n"}{end}' 2>/dev/null || true
}

# The Job controller reports a Pod it could not create here and nowhere else: there is no Pod
# to carry the status, and the Job's own conditions stay empty while it retries forever.
#
# `{.items[-1:]}` -- the last event, because the controller retries and logs the identical
# refusal every time, and `{.items[*]}` would hand the operator the same sentence N times on one
# line. This is the one place the rule at podName above is not followed, and the difference is
# what an empty answer *means*. There, empty means "the Pod is gone" and a jsonpath error
# silently producing it would be a misreading, so the query is written not to be able to error.
# Here, empty means "no FailedCreate event", and that is the correct reading whether it came from
# an empty list, from the error a slice of one raises, or from a kubectl that could not read
# events at all: no such event, keep waiting. Nothing downstream can mistake it for a refusal.
jobCreateFailure() {
    kubectl --namespace "$NAMESPACE" get events \
        --field-selector "involvedObject.kind=Job,involvedObject.name=$JOB_NAME,reason=FailedCreate" \
        -o jsonpath='{.items[-1:].message}' 2>/dev/null || true
}

# §23's run timeout, seen from outside. It is the one failure that erases its own evidence: the
# Job controller deletes the Pod, so this has to be read from the Job and has to be read
# wherever a Pod is being waited for -- a deadline short enough to expire before the Pod is
# scheduled otherwise looks exactly like a Pod that never appeared.
failIfDeadlineExceeded() {
    case $1 in
        *DeadlineExceeded*)
            fail timeout "the run hit job.yaml's activeDeadlineSeconds and was killed" \
                "§23 allows 30 minutes; raise activeDeadlineSeconds in job.yaml if the work genuinely takes longer" \
                "$1"
            ;;
    esac
}

# Waits for the Pod to exist, diagnosing the ways it may never appear.
waitForPod() {
    local deadline creation
    deadline=$(($(date +%s) + START_TIMEOUT))

    while :; do
        POD_NAME=$(podName)
        [ -z "$POD_NAME" ] || {
            log "Pod $POD_NAME created"
            return 0
        }

        failIfDeadlineExceeded "$(jobConditions)"

        creation=$(jobCreateFailure)
        case $creation in
            *"violates PodSecurity"*)
                fail admission "the Pod was refused by Pod Security Admission" \
                    "job.yaml must satisfy the restricted profile namespace.yaml enforces (§50)" \
                    "$creation"
                ;;
            *"service account"*)
                fail cluster "the Pod was refused: its ServiceAccount does not exist" \
                    "kubectl apply -f deploy/kubernetes/serviceaccount.yaml" "$creation"
                ;;
            ?*)
                fail cluster "the Job could not create its Pod" \
                    "read the message below; it is the API server refusing the Pod" "$creation"
                ;;
        esac

        [ "$(date +%s)" -lt "$deadline" ] ||
            fail cluster "the Job created no Pod within ${START_TIMEOUT}s" \
                "kubectl -n $NAMESPACE describe job $JOB_NAME" "$(jobConditions)"
        sleep "$POLL_INTERVAL"
    done
}

# Every way a container can fail to start, told apart by what the kubelet reports. Induced on a
# real cluster, one at a time; the substrings below are what it actually said.
classifyWaiting() {
    local reason=$1 message=$2

    case $reason in
        ErrImagePull | ImagePullBackOff | ErrImageNeverPull | InvalidImageName | RegistryUnavailable)
            # Order matters. The architecture mismatch also ends in "not found", so it has to be
            # tested first, and it is the one that looks least like what it is: the digest is
            # right, the registry is right, and the node cannot run any image in the manifest
            # list.
            case $message in
                *"no match for platform"*)
                    fail image "the image has no build for this node's architecture" \
                        "publish the image for this node's platform (images/agent CI builds linux/amd64 and linux/arm64), or schedule the run on a node it was built for" \
                        "$message"
                    ;;
                *"failed to authorize"* | *unauthorized* | *denied* | *"authentication required"*)
                    fail image "the registry refused the pull" \
                        "the package is private or does not exist: make ghcr.io/pmhood/sandcastle-agent public (images/agent/README.md), or give the namespace an imagePullSecret" \
                        "$message"
                    ;;
                *"not found"* | *"failed to resolve reference"* | *"manifest unknown"*)
                    fail image "the registry has no such image" \
                        "check the digest pinned in job.yaml against images/agent/README.md, \"Getting the current digest\"" \
                        "$message"
                    ;;
                *)
                    fail image "the image could not be pulled" \
                        "check the node's network path to the registry, then the digest in job.yaml" \
                        "$message"
                    ;;
            esac
            ;;

        CreateContainerConfigError)
            # #20's Secrets, seen from the far end. The message names the Secret when it is
            # missing and the key when it is misspelled, which is exactly the distinction an
            # operator should never have to dig for.
            fail credentials "the container could not be configured; a Secret or a key it needs is not there" \
                "./deploy/kubernetes/scripts/create-secrets.sh --verify, and compare the names against job.yaml's secretKeyRef entries" \
                "$message"
            ;;

        CreateContainerError | RunContainerError)
            fail runtime "the container could not be created" \
                "read the message below; it is the container runtime, not the agent" "$message"
            ;;
    esac
}

# What to do about a Pod no node will take. The scheduler counts nodes and names the predicate
# that ruled each one out, and one of those predicates is job.yaml's own: a node that has not
# been probed carries no `sandcastle.dev/agent-capable` label and is excluded on purpose (#30).
# That is the case an operator cannot act on from the message alone -- "didn't match Pod's node
# affinity/selector" reads like a mistake in the manifest, and on a cluster nobody has probed it
# is every node at once, so nothing runs and the cluster looks broken. Capacity is the other
# case and keeps the answer it had.
schedulingFix() {
    case $1 in
        *"node affinity/selector"* | *"nodeSelector"*)
            printf 'no node carries %s=true, and job.yaml only schedules onto one that does. Measure them: %s (deploy/kubernetes/README.md, "Which nodes can run the agent")' \
                "$CAPABILITY_LABEL" "$PROBE_SCRIPT"
            ;;
        *)
            printf 'free capacity, or lower the requests in job.yaml (§23)'
            ;;
    esac
}

# Says the Pod is unschedulable once, and only once, while it waits. Scheduling can still
# resolve -- a node comes back, another Pod finishes, someone runs the probe -- so this is not
# fatal until the start timeout, which is what reports it as such. The fix is said here as well
# as there because the difference between the two is $START_TIMEOUT seconds of silence.
reportScheduling() {
    local reason message
    IFS=$FIELD_SEPARATOR read -r reason message <<<"$(schedulingFacts)"
    [ "$reason" = Unschedulable ] || return 0
    [ "$SCHEDULING_REPORTED" = no ] || return 0
    SCHEDULING_REPORTED=yes
    log "Pod is not scheduled yet: $message"
    log "  $(schedulingFix "$message")"
}

# Waits for the container to start, or to fail to. Returns 0 while there is still a Pod whose
# logs can be followed, and 1 when the Pod is gone -- which is what the Job controller does to
# a run that exceeds its deadline. Either way reportOutcome has the last word on the result.
waitForContainer() {
    local deadline facts phase podReason waiting startedAt termReason termExit message
    deadline=$(($(date +%s) + START_TIMEOUT))

    while :; do
        facts=$(podFacts)
        [ -n "$facts" ] || return 1

        IFS=$FIELD_SEPARATOR read -r phase podReason waiting startedAt termReason termExit message <<<"$facts"
        classifyWaiting "$waiting" "$message"

        [ -z "$startedAt" ] || {
            log "Container started at $startedAt"
            return 0
        }
        # A container short enough to be over before the first poll never reports `running`;
        # so does a Pod that failed as a whole. Both still have logs, and reportOutcome is the
        # one place that decides what a finished run means.
        [ -z "$termReason" ] || return 0
        [ "$phase" != Failed ] || return 0

        reportScheduling

        [ "$(date +%s)" -lt "$deadline" ] || {
            IFS=$FIELD_SEPARATOR read -r podReason message <<<"$(schedulingFacts)"
            [ "$podReason" != Unschedulable ] ||
                fail scheduling "no node could take the Pod within ${START_TIMEOUT}s" \
                    "$(schedulingFix "$message")" "$message"
            fail cluster "the container did not start within ${START_TIMEOUT}s" \
                "kubectl -n $NAMESPACE describe pod $POD_NAME" "phase $phase, waiting: ${waiting:-none}"
        }
        sleep "$POLL_INTERVAL"
    done
}

# The run's own output, relayed verbatim on stdout: it is already §31-prefixed by the bootstrap,
# and nothing here rewrites it. `logs -f` ends when the container does; it fails when the Pod is
# deleted underneath it, which is the deadline case, and reportOutcome names that from the Job.
followLogs() {
    log "Following $POD_NAME (stdout below is the run's own)"
    log ""
    kubectl --namespace "$NAMESPACE" logs -f "$POD_NAME" --container agent || true
    log ""
}

reportSuccess() {
    log "Run $RUN_ID PASSED: the agent exited 0"
    log "  Repository: $GITHUB_REPOSITORY, issue #$GITHUB_ISSUE_NUMBER, agent $AGENT"
    log "  The Job and its Pod are removed automatically by ttlSecondsAfterFinished (§47);"
    log "  until then: kubectl -n $NAMESPACE logs -l sandcastle.run=$RUN_ID"
    log "  To remove it now: kubectl -n $NAMESPACE delete job $JOB_NAME"
    exit 0
}

# What the run ended as. The Job is asked first, because the two failures that leave no Pod
# behind -- the deadline, and an eviction the controller has already reaped -- are only
# recorded there.
reportOutcome() {
    local deadline conditions facts phase podReason waiting startedAt termReason termExit message
    deadline=$(($(date +%s) + FINISH_TIMEOUT))

    while :; do
        conditions=$(jobConditions)
        failIfDeadlineExceeded "$conditions"

        facts=$(podFacts)
        if [ -n "$facts" ]; then
            IFS=$FIELD_SEPARATOR read -r phase podReason waiting startedAt termReason termExit message <<<"$facts"

            [ "$podReason" != Evicted ] ||
                fail scheduling "the node evicted the Pod" \
                    "the node was under resource pressure; retry, or give the run a node with room (§23)" \
                    "$message"

            case $termReason in
                OOMKilled)
                    fail runtime "the container exceeded its memory limit and was killed" \
                        "raise the memory limit in job.yaml (§23 starts it at 4Gi)" \
                        "exit code $termExit"
                    ;;
                StartError | ContainerCannotRun)
                    fail runtime "the container was created but its process could not start" \
                        "this is the image's entrypoint, not the agent: read the message below" \
                        "$message"
                    ;;
                ContainerStatusUnknown)
                    fail cluster "the Pod was terminated before its container reported a status" \
                        "kubectl -n $NAMESPACE describe pod $POD_NAME" "$message"
                    ;;
                Completed | Error)
                    # A terminated container always carries an exit code; if one ever does not,
                    # the run is a failure of unknown size rather than a success.
                    termExit=${termExit:-1}
                    [ "$termExit" != 0 ] || reportSuccess
                    # The one failure that is the agent's own. Everything above this line
                    # happened to the run; this one happened inside it.
                    log ""
                    log "FAILED at the agent layer: the run started and exited $termExit"
                    log "  The container ran, so this is not a cluster problem: the cause is in"
                    log "  the run's own output above (§31 prefixes say which stage)."
                    reportWhereTheRunIs
                    exit "$termExit"
                    ;;
            esac
        elif [ -n "$conditions" ]; then
            fail cluster "the run's Pod is gone and the Job reports only this" \
                "kubectl -n $NAMESPACE describe job $JOB_NAME" "$conditions"
        fi

        [ "$(date +%s)" -lt "$deadline" ] ||
            fail cluster "the run's exit status did not appear within ${FINISH_TIMEOUT}s" \
                "kubectl -n $NAMESPACE describe job $JOB_NAME" "$(jobConditions)"
        sleep "$POLL_INTERVAL"
    done
}

main() {
    parseArgs "$@"
    [ -n "$RUN_ID" ] || generateRunId
    renderJob
    requireAgentMatchesManifest

    log "Run $RUN_ID"
    log "  Repository: $GITHUB_REPOSITORY"
    log "  Issue:      #$GITHUB_ISSUE_NUMBER"
    log "  Agent:      $AGENT"
    log "  Image:      $(manifestImage)"
    log "  Namespace:  $NAMESPACE"

    preflight
    applyJob
    waitForPod
    # No Pod, no logs: a run killed by its deadline is reported from the Job alone.
    if waitForContainer; then
        followLogs
    fi
    reportOutcome
}

main "$@"
