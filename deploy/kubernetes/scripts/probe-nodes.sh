#!/usr/bin/env bash
# Measures which nodes can run the agent binary, and labels them (#30, docs/ARCHITECTURE.md §36).
#
# job.yaml's `nodeSelector` says a run may only land on a node carrying
# `sandcastle.dev/agent-capable=true`. This is what writes that label, and the whole point is
# *how*: it runs the real binary -- `claude --version`, which makes no provider call and needs
# no credential -- from the exact image digest job.yaml pins, on the node in question, and
# labels the node by what happened. A node that runs it is `true`; a node where it dies is
# `false`; a node where the attempt never got as far as the binary is left alone, because that
# is not a measurement of anything.
#
# A hand-applied label would have been three lines instead of this file, and it would have been
# an operator's *claim*. #30 is what a wrong claim costs: the run cloned, branched, read the
# issue, started the CLI, and then died with `Illegal instruction (core dumped)` -- exit 132,
# SIGILL -- because the Bun executable the CLI ships as needs AVX2 and the node's 2009 Core 2
# Duo does not have it. A check on the CPU flag would have caught that particular cause and is
# still a proxy: it answers "does this node have AVX2", not "can this node run this binary",
# and the next incompatibility will be some other instruction, a glibc version, or a kernel
# feature. Running the binary is the only question worth asking, and it is cheap to ask.
#
# The costs, which README.md states for an operator rather than hiding here: the answer is about
# one image, so it has to be re-run when job.yaml's digest changes; a node added later is
# unlabelled, and therefore invisible rather than broken; and this needs permission to label
# nodes, which is cluster-scoped and more than launch-run.sh asks for.
#
# Usage:
#   ./deploy/kubernetes/scripts/probe-nodes.sh            # probe every node, label each
#   ./deploy/kubernetes/scripts/probe-nodes.sh red nova   # probe only these
#   ./deploy/kubernetes/scripts/probe-nodes.sh --show     # print what the cluster says, change nothing
#
# No credential is an input here and the Pod it runs has none: the probe reads a version string,
# so it needs neither Secret job.yaml's run reads, and a probe that mounted them would be putting
# a credential on a node that may not be able to run anything (§15, §52).

set -euo pipefail
# Off however this was invoked, as in every script here. This one handles no credential; the
# rule is uniform so that no script in this directory is the exception (§14).
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly MANIFEST_DIR="$(dirname "$SCRIPT_DIR")"
readonly JOB_MANIFEST="$MANIFEST_DIR/job.yaml"

readonly NAMESPACE="sandcastle-agents"
readonly SERVICE_ACCOUNT="sandcastle-agent"

# The one string this script and job.yaml both depend on. Changing it means changing both.
readonly CAPABILITY_LABEL="sandcastle.dev/agent-capable"

# What the label is a measurement *of*. A capability is not a property of a node alone: it is a
# property of one binary on one node, and job.yaml's digest moves (deliberately, §20). A node
# verified against last month's image is a claim about a binary this run will not execute, which
# is the same kind of unfounded claim as a hand-applied label -- only harder to see, because the
# label still says `true`.
#
# An annotation rather than a richer label value, for two reasons. A label value is capped at 63
# characters and `ghcr.io/...@sha256:<64 hex>` does not fit; and folding the digest into the
# value would make job.yaml's selector change with every image bump, so the manifest would carry
# the digest twice and a stale run would present as "no node matched" rather than as what it is.
# The selector stays a plain boolean; the provenance sits beside it, and launch-run.sh compares
# it with job.yaml before it applies anything.
readonly CAPABILITY_IMAGE_ANNOTATION="sandcastle.dev/agent-capable-image"

# `sandcastle-probe-` plus the node name has to stay a DNS-1123 label, so at most 63 characters.
readonly POD_PREFIX="sandcastle-probe-"
readonly NODE_NAME_MAX_LENGTH=46

readonly PROBE_TIMEOUT="${SANDCASTLE_PROBE_TIMEOUT:-300}"
readonly POLL_INTERVAL="${SANDCASTLE_POLL_INTERVAL:-2}"

# The separator the jsonpath below joins its fields with, as in launch-run.sh and for the same
# reason: IFS collapses repeated whitespace, so an empty field would shift every later one left.
readonly FIELD_SEPARATOR='|'

SHOW_ONLY=no
NODES=()
IMAGE=
AGENT=
CURRENT_POD=
PROBE_RESULT=
PROBE_DETAIL=
CAPABLE=0
INCAPABLE=0
UNMEASURED=0

# §31's shape, with this script's own prefix.
log() {
    printf '[PROBE] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [--show] [node...]

Runs the agent binary on each node and labels the node $CAPABILITY_LABEL=true or =false
according to what happened. With no node named, every node in the cluster is probed.

  --show   print the label each node currently carries and change nothing
  --help   this text

A node that has never been probed carries no label, and job.yaml will not schedule a run onto
it. See deploy/kubernetes/README.md, "Which nodes can run the agent".
EOF
}

parseArgs() {
    local arg

    for arg in "$@"; do
        case $arg in
            --help | -h)
                usage
                exit 0
                ;;
            --show) SHOW_ONLY=yes ;;
            -*) die "unrecognised option '$arg'" ;;
            *) NODES+=("$arg") ;;
        esac
    done
}

# Removes the Pod this script is in the middle of, however it leaves -- including the `set -e`
# path out of a failed kubectl, and a signal. A probe Pod left behind on a node is litter in a
# namespace §47 only reaps Jobs from.
cleanup() {
    [ -n "$CURRENT_POD" ] || return 0
    kubectl --namespace "$NAMESPACE" delete pod "$CURRENT_POD" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    CURRENT_POD=
}

requireCluster() {
    command -v kubectl >/dev/null ||
        die "kubectl not found on PATH (see deploy/kubernetes/README.md)"
    kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 ||
        die "namespace $NAMESPACE does not exist (kubectl apply -f deploy/kubernetes/namespace.yaml)"
    kubectl get serviceaccount "$SERVICE_ACCOUNT" --namespace "$NAMESPACE" >/dev/null 2>&1 ||
        die "ServiceAccount $SERVICE_ACCOUNT does not exist in $NAMESPACE (kubectl apply -f deploy/kubernetes/serviceaccount.yaml)"
}

# The literal value of one `env:` entry in job.yaml, as launch-run.sh reads it. The awk rather
# than yq is deliberate: yq is a validation-time dependency (validate.sh), and an operator
# probing their cluster should need no more installed than kubectl.
manifestEnvValue() {
    awk -v want="$1" '
        $1 == "-" && $2 == "name:" { current = $3; next }
        current == want && $1 == "value:" { gsub(/"/, "", $2); print $2; exit }' "$JOB_MANIFEST"
}

# The image and the agent come from job.yaml and are never defaults here: a probe that measured
# some other image, or some other binary, would be labelling nodes for a workload that is not
# the one this repository runs. Both are validated before being substituted into a manifest,
# which is render-job.sh's rule applied to this script's own inputs.
readManifest() {
    [ -f "$JOB_MANIFEST" ] || die "job.yaml is not next to this script; nothing to probe for"

    IMAGE=$(awk '$1 == "image:" { print $2; exit }' "$JOB_MANIFEST")
    AGENT=$(manifestEnvValue AGENT)

    [[ $IMAGE =~ ^[A-Za-z0-9./_-]+@sha256:[0-9a-f]{64}$ ]] ||
        die "job.yaml's image is not a digest-pinned reference: '${IMAGE:-none}'"
    [[ $AGENT =~ ^[a-z][a-z0-9-]*$ ]] ||
        die "job.yaml sets no usable AGENT: '${AGENT:-none}'"
}

# Every node, when none was named. `-o jsonpath` over the list rather than `get nodes -o name`,
# so the names arrive bare and one per line.
allNodes() {
    local names
    names=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1) ||
        die "could not list the cluster's nodes: $names"
    [ -n "$names" ] || die "the cluster reports no nodes"
    printf '%s\n' "$names"
}

resolveNodes() {
    local node

    if [ ${#NODES[@]} -eq 0 ]; then
        while IFS= read -r node; do
            [ -z "$node" ] || NODES+=("$node")
        done < <(allNodes)
    fi

    for node in "${NODES[@]}"; do
        [[ $node =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
            die "'$node' is not a node name"
        [ ${#node} -le $NODE_NAME_MAX_LENGTH ] ||
            die "node name '$node' is too long for a probe Pod named $POD_PREFIX$node"
    done
}

# The label and the image it was measured against, joined by $FIELD_SEPARATOR. Both keys contain
# dots, which jsonpath reads as path separators, so each dot inside the key is escaped; the
# bracket form kubectl also accepts does not parse here.
nodeCapability() {
    kubectl get node "$1" \
        -o jsonpath='{.metadata.labels.sandcastle\.dev/agent-capable}{"|"}{.metadata.annotations.sandcastle\.dev/agent-capable-image}' \
        2>/dev/null || true
}

# How many nodes a run could actually be scheduled onto: labelled `true` *and* recorded against
# the image job.yaml pins, which is the pair launch-run.sh requires. Asked of the whole cluster
# rather than counted from this invocation's nodes, because probing one node says nothing about
# the others and "0 capable" out of a subset is not "no node can run this".
launchableNodes() {
    kubectl get nodes -l "$CAPABILITY_LABEL=true" \
        -o jsonpath='{range .items[*]}{.metadata.annotations.sandcastle\.dev/agent-capable-image}{"\n"}{end}' \
        2>/dev/null | grep -c -F -x "$IMAGE" || true
}

# What the cluster currently claims, without probing anything. Four states, and the two that are
# not plain yes/no are the ones worth printing plainly: an unlabelled node is not "false", it is
# unmeasured; and a node measured against some other image is not "true" either, whatever its
# label says. job.yaml excludes the unmeasured, and launch-run.sh refuses to launch against the
# stale, so neither is a silent state.
showNodes() {
    local node capability label image

    log "$CAPABILITY_LABEL, as the cluster has it now:"
    for node in "${NODES[@]}"; do
        capability=$(nodeCapability "$node")
        IFS=$FIELD_SEPARATOR read -r label image <<<"$capability"
        case $label in
            true)
                if [ "$image" = "$IMAGE" ]; then
                    log "  $node: true -- the agent binary ran here, from job.yaml's image"
                else
                    log "  $node: true, but measured against ${image:-nothing this script wrote}"
                    log "  $node:   job.yaml now pins $IMAGE, so this answer is about another binary"
                fi
                ;;
            false)
                log "  $node: false -- the agent binary died here (${image:-image not recorded})"
                ;;
            *) log "  $node: (no label) -- never probed; no run will be scheduled onto it" ;;
        esac
    done

    warnIfNothingLaunchable
}

# Said by both halves of this script, because "nothing will run" is the fact an operator has to
# leave with, whether they asked for a measurement or just for the current answer.
warnIfNothingLaunchable() {
    [ "$(launchableNodes)" -eq 0 ] || return 0
    log ""
    log "No node is known to run job.yaml's image, so no run can be launched: job.yaml"
    log "requires $CAPABILITY_LABEL=true, and launch-run.sh additionally requires that the"
    log "node was measured against the image job.yaml pins now. Measure them: $0"
}

# The probe Pod: the agent binary, the pinned image, one node, nothing else.
#
# `nodeName` and not a `nodeSelector`, which is the one place this script deliberately skips the
# scheduler. The probe is a question about a *named* node, and the scheduler is exactly what
# would refuse to answer it: a node that has been cordoned -- #30's interim workaround was
# `kubectl cordon nova` -- takes no scheduled Pod, and a node with no capability label is one
# job.yaml's own selector excludes, which would make the probe unable to measure any node that
# has not already been measured.
#
# No env, no envFrom, no secretKeyRef and no volumes: `--version` needs none of them, and the
# §50 context is here because namespace.yaml enforces the restricted profile on everything in
# this namespace, the probe included.
probeManifest() {
    local node=$1

    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_PREFIX$node
  namespace: $NAMESPACE
  labels:
    app: sandcastle
    sandcastle.probe: "$node"
spec:
  nodeName: $node
  restartPolicy: Never
  serviceAccountName: $SERVICE_ACCOUNT
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $IMAGE
      command: ["$AGENT", "--version"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: "1"
          memory: 512Mi
EOF
}

# phase|waiting.reason|terminated.exitCode|waiting.message, joined by $FIELD_SEPARATOR. The
# message is last for the same reason as in launch-run.sh: it may contain anything, newlines
# included, and `read` would drop whatever followed it.
podFacts() {
    kubectl --namespace "$NAMESPACE" get pod "$1" \
        -o jsonpath='{.status.phase}{"|"}{.status.containerStatuses[*].state.waiting.reason}{"|"}{.status.containerStatuses[*].state.terminated.exitCode}{"|"}{.status.containerStatuses[*].state.waiting.message}' \
        2>/dev/null || true
}

# Runs the binary on one node and sets PROBE_RESULT and PROBE_DETAIL. Three outcomes, and the
# third is the one that matters most:
#
#   capable    the binary ran and exited 0
#   incapable  the binary ran and did not (SIGILL leaves 132, and prints nothing at all)
#   unmeasured the container never ran, so nothing was measured
#
# `unmeasured` never writes a label, and never removes one. An image that cannot be pulled says
# nothing about whether the node could execute it, and a probe that recorded `false` for it
# would be manufacturing exactly the kind of unfounded claim this script exists to avoid.
probeNode() {
    local node=$1 deadline facts phase waiting exitCode message output
    local pod="$POD_PREFIX$node"

    PROBE_RESULT=unmeasured
    PROBE_DETAIL=

    # A probe interrupted last time leaves its Pod behind, and applying over it would read that
    # one's result as this one's.
    kubectl --namespace "$NAMESPACE" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true

    log "$node: running \`$AGENT --version\` from $IMAGE"
    CURRENT_POD=$pod
    if ! output=$(probeManifest "$node" | kubectl apply --namespace "$NAMESPACE" -f - 2>&1); then
        PROBE_DETAIL="the API server refused the probe Pod: $output"
        cleanup
        return 0
    fi

    deadline=$(($(date +%s) + PROBE_TIMEOUT))
    while :; do
        facts=$(podFacts "$pod")
        IFS=$FIELD_SEPARATOR read -r phase waiting exitCode message <<<"$facts"

        if [ -n "$exitCode" ]; then
            output=$(kubectl --namespace "$NAMESPACE" logs "$pod" 2>/dev/null | head -n 1 || true)
            if [ "$exitCode" -eq 0 ]; then
                PROBE_RESULT=capable
                PROBE_DETAIL="exit 0${output:+, \`$output\`}"
            else
                PROBE_RESULT=incapable
                # 132 is 128+4: SIGILL, which is what an unsupported instruction looks like and
                # what #30 was. Named because the binary itself prints nothing -- the "Illegal
                # instruction" line comes from a shell, and there is no shell in this Pod.
                PROBE_DETAIL="exit $exitCode${output:+, \`$output\`}"
                [ "$exitCode" -ne 132 ] ||
                    PROBE_DETAIL="exit 132 (SIGILL: the binary hit an instruction this CPU does not have)"
            fi
            break
        fi

        # Something that will never resolve on its own, said as soon as it is known rather than
        # after the timeout. The message is the kubelet's own.
        case $waiting in
            ErrImagePull | ImagePullBackOff | InvalidImageName | ErrImageNeverPull)
                PROBE_DETAIL="the image could not be pulled onto $node, so the binary never ran: ${message:-$waiting}"
                break
                ;;
        esac

        [ "$(date +%s)" -lt "$deadline" ] || {
            PROBE_DETAIL="the probe container did not run within ${PROBE_TIMEOUT}s (phase ${phase:-unknown}, waiting: ${waiting:-none})"
            break
        }
        sleep "$POLL_INTERVAL"
    done

    cleanup
}

# `true` and `false` rather than labelling only the capable ones, because "measured and it does
# not work" and "nobody has looked" are different facts about a node and an operator reading
# `kubectl get nodes -L` should be able to tell them apart. job.yaml's selector matches `true`,
# so both non-true states keep runs off the node either way.
#
# The label goes on first and the annotation second, which is the order that fails safely. If
# the second call is the one that fails, the node is left claiming `true` with the *previous*
# image recorded beside it, and launch-run.sh refuses to launch against a node whose recorded
# image is not job.yaml's. The other order would leave this image recorded beside the previous
# verdict, which reads as verified and is not.
labelNode() {
    local node=$1 value=$2 output

    output=$(kubectl label node "$node" "$CAPABILITY_LABEL=$value" --overwrite 2>&1) ||
        die "could not label node $node: $output"
    output=$(kubectl annotate node "$node" "$CAPABILITY_IMAGE_ANNOTATION=$IMAGE" --overwrite 2>&1) ||
        die "node $node is labelled $CAPABILITY_LABEL=$value but could not be annotated with the image it was measured against, so the label cannot be trusted: $output"
}

probeAll() {
    local node

    for node in "${NODES[@]}"; do
        probeNode "$node"
        case $PROBE_RESULT in
            capable)
                labelNode "$node" true
                CAPABLE=$((CAPABLE + 1))
                log "  $node: CAPABLE -- $PROBE_DETAIL. Labelled $CAPABILITY_LABEL=true, for this image"
                ;;
            incapable)
                labelNode "$node" false
                INCAPABLE=$((INCAPABLE + 1))
                log "  $node: NOT CAPABLE -- $PROBE_DETAIL. Labelled $CAPABILITY_LABEL=false, for this image"
                ;;
            *)
                UNMEASURED=$((UNMEASURED + 1))
                log "  $node: NOT MEASURED -- $PROBE_DETAIL"
                log "  $node: its label is left exactly as it was; nothing was measured here"
                ;;
        esac
    done
}

# The summary is the thing an operator acts on, so it says what the cluster can now do rather
# than how many calls succeeded.
report() {
    log ""
    log "$CAPABLE capable, $INCAPABLE not capable, $UNMEASURED not measured"

    # Only worth asking the cluster when this run measured nothing that can take a Job: a node
    # labelled capable a moment ago is one, and another node probed last week may be another.
    [ "$CAPABLE" -gt 0 ] || warnIfNothingLaunchable
    [ "$UNMEASURED" -eq 0 ] || {
        log "Re-run this for the nodes above that were not measured; until then they keep"
        log "whatever label they had, which may be older than job.yaml's image."
        exit 1
    }
}

main() {
    parseArgs "$@"
    requireCluster
    readManifest
    resolveNodes

    if [ "$SHOW_ONLY" = yes ]; then
        showNodes
        return 0
    fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    probeAll
    report
}

main "$@"
