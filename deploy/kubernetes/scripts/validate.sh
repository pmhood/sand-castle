#!/usr/bin/env bash
# Static validation of the manifests next to this script (docs/ARCHITECTURE.md §19-§24, §50).
#
# Two halves, because they catch different mistakes:
#
#   1. schema validation (kubeconform), which catches a manifest the API server would reject;
#   2. property assertions (yq), which catch a manifest the API server would happily accept and
#      that is nonetheless wrong -- a floating image tag, a missing backoffLimit, a security
#      context field someone dropped, a credential written in as a literal value.
#
# Neither half needs a cluster, which is the point: CI cannot reach one. `kubectl apply
# --dry-run=server` against the real cluster is the useful extra the README documents, not a
# requirement of this script.
#
# Every assertion is a call to check/checkMatches below, which report and count a failure
# explicitly; none is a bare `[[ ]]` that bash 3.2 would ignore (the house rule #8 established).
# scripts/prove-checks.sh proves each one bites by breaking the manifest and re-running this.
#
# Usage:
#   ./deploy/kubernetes/scripts/validate.sh

set -euo pipefail
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly MANIFEST_DIR="$(dirname "$SCRIPT_DIR")"

# Fixed, meaningless run context: this renders the template so it can be checked, it does not
# describe a run anyone will start.
readonly SAMPLE_RUN_ID="validate-0000"
readonly SAMPLE_REPOSITORY="octocat/Hello-World"
readonly SAMPLE_ISSUE_NUMBER="1"

# kubeconform downloads the schema for each kind it sees. One cache directory, reused across
# runs, keeps that to one download per kind per machine -- which matters to prove-checks.sh,
# where this script runs once per mutation.
readonly SCHEMA_CACHE="${KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-schema-cache}"

readonly IMAGE_DIGEST_PATTERN='^ghcr\.io/pmhood/sandcastle-agent@sha256:[0-9a-f]{64}$'
# Anything that looks like a credential must arrive by reference, never as a literal value.
readonly CREDENTIAL_NAME_PATTERN='TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|OAUTH'

PASSED=0
FAILED=0

log() {
    printf '[VALIDATE] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# Both assertions report the value they actually saw, so a failure names the mistake rather
# than the expectation. A missing field reads as `null`, which is how a deleted one is caught.
check() {
    local description=$1 expected=$2 actual=$3

    if [ "$actual" = "$expected" ]; then
        PASSED=$((PASSED + 1))
        return 0
    fi

    FAILED=$((FAILED + 1))
    log "FAIL: $description -- expected '$expected', got '$actual'"
}

checkMatches() {
    local description=$1 pattern=$2 actual=$3

    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASSED=$((PASSED + 1))
        return 0
    fi

    FAILED=$((FAILED + 1))
    log "FAIL: $description -- '$actual' does not match /$pattern/"
}

requireTools() {
    command -v kubeconform >/dev/null ||
        die "kubeconform not found (brew install kubeconform, or see deploy/kubernetes/README.md)"
    command -v yq >/dev/null ||
        die "yq not found (brew install yq, or see deploy/kubernetes/README.md)"
}

# Reads one expression out of one manifest. A missing path yields `null` rather than an error,
# so every assertion below reports a dropped field instead of aborting the run at the first one.
read_() {
    local file=$1 expression=$2
    yq "$expression" "$file"
}

# -strict rejects fields no schema knows about, which is what catches a misspelled one:
# `readOnlyRootFileSystem` is silently ignored by the API server and by a non-strict check.
#
# The summary is asserted as well as the exit status, because kubeconform exits 0 having
# validated nothing -- it skips a file whose name it does not recognise, which is how the first
# draft of this script "schema-checked" a rendered Job in a temporary file with no .yaml suffix.
schemaOf() {
    local file=$1 summary status=0

    summary=$(kubeconform -strict -summary -cache "$SCHEMA_CACHE" "$file" 2>&1) || status=$?
    [ "$status" -eq 0 ] || log "$summary"
    check "kubeconform accepts $(basename "$file")" "0" "$status"
    checkMatches "kubeconform actually read $(basename "$file")" 'Valid: [1-9]' "$summary"
}

schemaCheck() {
    local job=$1 file

    log "Schema-validating with kubeconform $(kubeconform -v)"
    mkdir -p "$SCHEMA_CACHE"
    for file in "$MANIFEST_DIR"/*.yaml; do
        [ "$(basename "$file")" != "job.yaml" ] || continue # unrendered; $job is its rendering
        schemaOf "$file"
    done
    schemaOf "$job"
}

checkNamespace() {
    local file="$MANIFEST_DIR/namespace.yaml"

    check "namespace is sandcastle-agents (§21)" \
        "sandcastle-agents" "$(read_ "$file" '.metadata.name')"
    check "namespace enforces the restricted Pod Security standard (§50)" \
        "restricted" "$(read_ "$file" '.metadata.labels."pod-security.kubernetes.io/enforce"')"
}

checkServiceAccount() {
    local file="$MANIFEST_DIR/serviceaccount.yaml"

    check "the agent ServiceAccount is dedicated, not default (§50)" \
        "sandcastle-agent" "$(read_ "$file" '.metadata.name')"
    check "the ServiceAccount mounts no Kubernetes API token (§50)" \
        "false" "$(read_ "$file" '.automountServiceAccountToken')"
}

checkJobShape() {
    local job=$1

    check "the workload is a Job, not a Pod (§19)" "Job" "$(read_ "$job" '.kind')"
    check "the Job runs in the agent namespace (§21)" \
        "sandcastle-agents" "$(read_ "$job" '.metadata.namespace')"
    check "a run is not retried silently (§20)" "0" "$(read_ "$job" '.spec.backoffLimit')"
    check "the Pod is not restarted in place (§20)" \
        "Never" "$(read_ "$job" '.spec.template.spec.restartPolicy')"
    check "the run times out after 30 minutes (§23)" \
        "1800" "$(read_ "$job" '.spec.activeDeadlineSeconds')"
    check "a finished Job is cleaned up on a TTL (§47)" \
        "true" "$(read_ "$job" '(.spec.ttlSecondsAfterFinished // 0) > 0')"
}

checkJobLabels() {
    local job=$1

    check "the Job carries app: sandcastle (§20)" \
        "sandcastle" "$(read_ "$job" '.metadata.labels.app')"
    check "the Job is selectable by run (§20)" \
        "$SAMPLE_RUN_ID" "$(read_ "$job" '.metadata.labels."sandcastle.run"')"
    check "the Pod carries app: sandcastle (§20)" \
        "sandcastle" "$(read_ "$job" '.spec.template.metadata.labels.app')"
    check "the Pod is selectable by run (§20)" \
        "$SAMPLE_RUN_ID" "$(read_ "$job" '.spec.template.metadata.labels."sandcastle.run"')"
}

checkImageIsPinned() {
    local job=$1

    checkMatches "the image is pinned by digest, not by a tag (§20)" \
        "$IMAGE_DIGEST_PATTERN" \
        "$(read_ "$job" '.spec.template.spec.containers[0].image')"
}

checkSecurityContext() {
    local job=$1 pod=".spec.template.spec" container=".spec.template.spec.containers[0]"

    check "the agent gets no Kubernetes API token (§50)" \
        "false" "$(read_ "$job" "$pod.automountServiceAccountToken")"
    check "the agent runs as its own ServiceAccount (§50)" \
        "sandcastle-agent" "$(read_ "$job" "$pod.serviceAccountName")"
    check "the agent runs as a non-root user (§50)" \
        "true" "$(read_ "$job" "$pod.securityContext.runAsNonRoot")"
    check "the agent runs as uid 1000, the image's node user (§50)" \
        "1000" "$(read_ "$job" "$pod.securityContext.runAsUser")"
    check "the agent runs under the default seccomp profile (§50)" \
        "RuntimeDefault" "$(read_ "$job" "$pod.securityContext.seccompProfile.type")"
    check "the agent cannot escalate privileges (§50)" \
        "false" "$(read_ "$job" "$container.securityContext.allowPrivilegeEscalation")"
    check "the root filesystem is read-only (§50)" \
        "true" "$(read_ "$job" "$container.securityContext.readOnlyRootFilesystem")"
    check "every capability is dropped (§50)" \
        "ALL" "$(read_ "$job" "$container.securityContext.capabilities.drop | join(\",\")")"
}

checkResources() {
    local job=$1 resources=".spec.template.spec.containers[0].resources"

    check "CPU request is 500m (§23)" "500m" "$(read_ "$job" "$resources.requests.cpu")"
    check "memory request is 1Gi (§23)" "1Gi" "$(read_ "$job" "$resources.requests.memory")"
    check "CPU limit is 2 (§23)" "2" "$(read_ "$job" "$resources.limits.cpu")"
    check "memory limit is 4Gi (§23)" "4Gi" "$(read_ "$job" "$resources.limits.memory")"
}

# §24 plus the writable set the README records: /workspace, $HOME and /tmp, each an emptyDir
# because none of them has to outlive the Pod.
checkWritablePaths() {
    local job=$1 pod=".spec.template.spec"

    check "the writable paths are mounted (§24, §50)" \
        "/home/node /tmp /workspace" \
        "$(read_ "$job" "[$pod.containers[0].volumeMounts[].mountPath] | sort | join(\" \")")"
    # Both sides are compared against the same literal, which is what pins the pairing: a mount
    # naming a volume that does not exist fails here rather than at the API server.
    check "each mount names one of the three volumes (§24)" \
        "home tmp workspace" \
        "$(read_ "$job" "[$pod.containers[0].volumeMounts[].name] | sort | join(\" \")")"
    check "the volumes are those three (§24)" \
        "home tmp workspace" \
        "$(read_ "$job" "[$pod.volumes[].name] | sort | join(\" \")")"
    check "every volume is an emptyDir (§24)" \
        "3" "$(read_ "$job" "[$pod.volumes[] | select(has(\"emptyDir\"))] | length")"
}

# The #14 rule, as it applies to a Pod spec: a credential is either genuinely present or the
# Pod does not start. An `optional: true` reference to a key that does not exist, or a literal
# empty `value:`, is how an unset credential becomes an empty one -- which is what made the
# Claude CLI write its config into the agent's checkout.
checkCredentialWiring() {
    local job=$1 env=".spec.template.spec.containers[0].env"

    check "no environment entry is an empty literal value (#14)" \
        "0" "$(read_ "$job" "[${env}[] | select(.value == \"\")] | length")"
    check "no secret reference is optional (#14)" \
        "0" "$(read_ "$job" "[${env}[] | select(.valueFrom.secretKeyRef.optional == true)] | length")"
    check "no credential is written in as a literal value (§15, §52)" \
        "0" "$(read_ "$job" \
            "[${env}[] | select(.name | test(\"$CREDENTIAL_NAME_PATTERN\")) | select(has(\"value\"))] | length")"
    check "credentials arrive by secretKeyRef, and these are the ones (#20)" \
        "CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN" \
        "$(read_ "$job" "[${env}[] | select(has(\"valueFrom\")) | .name] | sort | join(\" \")")"
    # Both lists are exhaustive on purpose: between them they pin every environment entry the
    # container gets, so a variable added without a decision -- an OPENAI_API_KEY that does not
    # in fact authenticate Codex (#3), say -- fails here whichever way it was wired.
    check "the run context arrives as plain values, and these are the ones (§15)" \
        "AGENT GITHUB_ISSUE_NUMBER GITHUB_REPOSITORY SANDCASTLE_RUN_ID" \
        "$(read_ "$job" "[${env}[] | select(has(\"value\")) | .name] | sort | join(\" \")")"
}

main() {
    local workDir job

    requireTools

    # A directory rather than a bare temporary file, so the rendering keeps its .yaml name:
    # kubeconform decides what to read from the file extension.
    workDir=$(mktemp -d)
    # shellcheck disable=SC2064 # $workDir is expanded now on purpose.
    trap "rm -rf '$workDir'" EXIT
    job="$workDir/job.yaml"
    "$SCRIPT_DIR/render-job.sh" "$SAMPLE_RUN_ID" "$SAMPLE_REPOSITORY" "$SAMPLE_ISSUE_NUMBER" >"$job"

    schemaCheck "$job"

    checkNamespace
    checkServiceAccount
    checkJobShape "$job"
    checkJobLabels "$job"
    checkImageIsPinned "$job"
    checkSecurityContext "$job"
    checkResources "$job"
    checkWritablePaths "$job"
    checkCredentialWiring "$job"

    log "$PASSED assertions passed, $FAILED failed"
    [ "$FAILED" -eq 0 ] || exit 1
}

main "$@"
