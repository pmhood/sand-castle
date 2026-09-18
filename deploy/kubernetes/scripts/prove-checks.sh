#!/usr/bin/env bash
# Proves that scripts/validate.sh actually bites.
#
# A suite can be green and prove nothing: #8's audit of this repository found 49 assertions
# that were inert. The house rule that came out of it is to verify every check by breaking the
# thing it guards, never by reverting the assertion -- and the first draft of validate.sh is
# why it is automated here rather than performed once by hand: it "schema-checked" a rendered
# Job that kubeconform was silently skipping, and passed.
#
# So: copy the manifests, break exactly one property, run validate.sh against the copy, and
# require it to fail. A mutation that validation still passes is an assertion that is not there.
#
# Usage:
#   ./deploy/kubernetes/scripts/prove-checks.sh

set -euo pipefail
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly MANIFEST_DIR="$(dirname "$SCRIPT_DIR")"

# Three fields per mutation -- manifest, mutation, and the property it removes -- flat rather
# than nested, because bash 3.2 (what a developer Mac runs) has no nested arrays.
#
# A mutation is normally a yq expression. A mutation that begins with `---` is instead a literal
# YAML document appended to the manifest, which is the only way to express the two mistakes yq
# cannot make for us: a second document smuggled into an existing file, and a whole new manifest
# file appearing in the directory.
readonly MUTATIONS=(
    job.yaml
    '.spec.template.spec.containers[0].image = "ghcr.io/pmhood/sandcastle-agent:latest"'
    'the image is pinned by digest, not by a tag'

    job.yaml
    'del(.spec.backoffLimit)'
    'backoffLimit is set at all (absent means 6 retries)'

    job.yaml
    '.spec.backoffLimit = 3'
    'backoffLimit is 0'

    job.yaml
    '.spec.template.spec.restartPolicy = "OnFailure"'
    'restartPolicy is Never'

    job.yaml
    'del(.spec.activeDeadlineSeconds)'
    'the run has a 30-minute deadline'

    job.yaml
    'del(.spec.ttlSecondsAfterFinished)'
    'a finished Job is cleaned up on a TTL'

    job.yaml
    '.spec.ttlSecondsAfterFinished = 1'
    'the TTL is the 24 hours §47 was reasoned into, not merely some number'

    job.yaml
    '.spec.parallelism = 2'
    'one run means one Pod at a time'

    job.yaml
    '.spec.completions = 3'
    'one run means one completion'

    job.yaml
    'del(.spec.template.metadata.labels."sandcastle.run")'
    'the Pod is selectable by run'

    job.yaml
    'del(.spec.template.spec.securityContext.runAsNonRoot)'
    'the agent runs as a non-root user'

    job.yaml
    '.spec.template.spec.securityContext.runAsUser = 0'
    'the agent runs as uid 1000'

    job.yaml
    'del(.spec.template.spec.securityContext.seccompProfile)'
    'the agent runs under the default seccomp profile'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation = true'
    'the agent cannot escalate privileges'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem = false'
    'the root filesystem is read-only'

    job.yaml
    'del(.spec.template.spec.containers[0].securityContext.capabilities)'
    'every capability is dropped'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.capabilities.add = ["SYS_ADMIN"]'
    'no capability is added back after drop: [ALL]'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.privileged = true'
    'no container is privileged'

    job.yaml
    '.spec.template.spec.hostPID = true'
    'the Pod shares none of the host namespaces'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.runAsUser = 0'
    'nothing else is set in the container security context, including an override of the Pod uid'

    job.yaml
    '.spec.template.spec.securityContext.seLinuxOptions = {"type": "spc_t"}'
    'nothing else is set in the Pod security context'

    job.yaml
    '.spec.template.spec.nodeName = "red"'
    'nothing else is set in the Pod spec, including a way around the scheduler'

    job.yaml
    'del(.spec.template.spec.nodeSelector)'
    'a run only lands on a node measured to run the agent binary (#30)'

    job.yaml
    '.spec.template.spec.nodeSelector = {"kubernetes.io/os": "linux"}'
    'the constraint is the capability one, not merely some constraint'

    job.yaml
    '.spec.template.spec.nodeSelector."sandcastle.dev/agent-capable" = "false"'
    'the selector names the nodes that can run the agent, not the ones that cannot'

    # `style=""` cannot express this one: yq re-quotes a string whose text would otherwise parse
    # as a boolean, so the mutation has to write the boolean itself -- which is exactly what an
    # unquoted `sandcastle.dev/agent-capable: true` in job.yaml is.
    job.yaml
    '.spec.template.spec.nodeSelector."sandcastle.dev/agent-capable" = true'
    'the selector value is a label value and not a YAML boolean'

    job.yaml
    '.spec.suspend = true'
    'nothing else is set in the Job spec'

    job.yaml
    '.spec.template.metadata.annotations = {"container.apparmor.security.beta.kubernetes.io/agent": "unconfined"}'
    'nothing else is set in the Pod template metadata, including an AppArmor override'

    job.yaml
    '.spec.template.spec.containers[0].securityContext.readOnlyRootFileSystem = true'
    'a misspelled security field is rejected rather than silently ignored'

    job.yaml
    '.spec.template.spec.automountServiceAccountToken = true'
    'the Pod mounts no Kubernetes API token'

    serviceaccount.yaml
    '.automountServiceAccountToken = true'
    'the ServiceAccount mounts no Kubernetes API token'

    job.yaml
    'del(.spec.template.spec.containers[0].resources.limits)'
    'the agent has CPU and memory limits'

    job.yaml
    'del(.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/tmp"))'
    'every writable path is mounted'

    job.yaml
    '.spec.template.spec.volumes[0] = {"name": "workspace", "hostPath": {"path": "/srv/workspace"}}'
    'the workspace is an emptyDir, not a host path'

    job.yaml
    '.spec.template.spec.containers[0].volumeMounts[0].name = "not-a-volume"'
    'each mount names a volume that exists'

    job.yaml
    '(.spec.template.spec.containers[0].env[] | select(.name == "GITHUB_TOKEN")) = {"name": "GITHUB_TOKEN", "value": "ghp-not-a-real-token"}'
    'no credential is written in as a literal value'

    job.yaml
    '(.spec.template.spec.containers[0].env[] | select(.name == "GITHUB_TOKEN")).valueFrom.secretKeyRef.optional = true'
    'no secret reference is optional'

    job.yaml
    '.spec.template.spec.containers[0].env += [{"name": "CLAUDE_CONFIG_DIR", "value": ""}]'
    'no environment entry is an empty literal value'

    job.yaml
    '.spec.template.spec.containers[0].env += [{"name": "CLAUDE_CONFIG_DIR"}]'
    'an entry with neither value nor valueFrom, which Kubernetes materialises as empty'

    job.yaml
    '.spec.template.spec.containers[0].envFrom = [{"secretRef": {"name": "sandcastle-misc", "optional": true}}]'
    'no environment arrives wholesale, and unnamed, through envFrom'

    job.yaml
    '.spec.template.spec.containers += [{"name": "sidecar", "image": "busybox", "env": [{"name": "GITHUB_TOKEN", "value": "ghp-not-a-real-token"}]}]'
    'the container the assertions read is the only container there is'

    job.yaml
    '.spec.template.spec.initContainers = [{"name": "setup", "image": "busybox", "securityContext": {"privileged": true}}]'
    'no init container runs before the agent, unexamined'

    job.yaml
    '.spec.template.spec.ephemeralContainers = [{"name": "debug", "image": "busybox"}]'
    'no ephemeral container is declared alongside the agent'

    job.yaml
    '.metadata.labels."sandcastle.run" style=""'
    'a placeholder stays quoted, so a numeric-shaped run ID renders as text'

    job.yaml
    '(.spec.template.spec.containers[0].env[] | select(.name == "SANDCASTLE_RUN_ID")).value style=""'
    'an environment value stays quoted, so a numeric-shaped run ID renders as text'

    job.yaml
    '.spec.template.spec.containers[0].env += [{"name": "OPENAI_API_KEY", "valueFrom": {"secretKeyRef": {"name": "sandcastle-openai", "key": "key"}}}]'
    'the set of credential variables is exactly the agreed one'

    job.yaml
    'del(.spec.template.spec.containers[0].env[] | select(.name == "AGENT"))'
    'the set of plain run-context variables is exactly the agreed one'

    namespace.yaml
    '.metadata.name = "default"'
    'agents run in their own namespace'

    namespace.yaml
    '.metadata.labels."pod-security.kubernetes.io/enforce" = "privileged"'
    'the namespace enforces the restricted Pod Security standard'

    server-serviceaccount.yaml
    '.metadata.name = "sandcastle-agent"'
    'the server has its own ServiceAccount, distinct from the agent'"'"'s'

    server-serviceaccount.yaml
    '.metadata.namespace = "default"'
    'the server ServiceAccount lives in sandcastle-agents'

    server-role.yaml
    '.kind = "ClusterRole"'
    'the server RBAC is a namespaced Role, not a ClusterRole (§22 forbids cluster-admin)'

    server-role.yaml
    '.metadata.namespace = "default"'
    'the server Role only grants within sandcastle-agents'

    server-role.yaml
    '.rules[0].verbs = ["create", "delete"]'
    'the verb Phase 3 (§37) actually calls is exactly create, not wider'

    server-role.yaml
    '.rules[1].verbs = ["get", "list", "watch", "delete", "update"]'
    'the job verbs granted ahead of use are exactly §22'"'"'s get/list/watch/delete'

    server-role.yaml
    '.rules[2].resources = ["pods", "pods/exec"]'
    'pods/exec is not granted -- §22 defers it'

    server-role.yaml
    '.rules[3].resources = ["pods/log", "pods/exec"]'
    'pods/exec is not granted through the pod-logs rule either'

    server-role.yaml
    '.rules[0].verbs = ["*"]'
    'no rule grants a wildcard verb'

    server-role.yaml
    '.rules[2].resources = ["*"]'
    'no rule grants a wildcard resource'

    server-role.yaml
    '.rules[2].apiGroups = ["*"]'
    'no rule grants a wildcard API group'

    server-role.yaml
    '.rules += [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]}]'
    'the Role grants no rule beyond the four §22 asks for'

    server-rolebinding.yaml
    '.kind = "ClusterRoleBinding"'
    'the server binding is a RoleBinding, not a ClusterRoleBinding'

    server-rolebinding.yaml
    '.metadata.namespace = "default"'
    'the server binding only exists in sandcastle-agents'

    server-rolebinding.yaml
    '.roleRef.kind = "ClusterRole"'
    'the server binding points at a Role, not a ClusterRole'

    server-rolebinding.yaml
    '.roleRef.name = "sandcastle-agent"'
    'the server binding points at the server Role, not some other one'

    server-rolebinding.yaml
    '.subjects[0].name = "sandcastle-agent"'
    'the server binding'"'"'s subject is the server ServiceAccount, not the agent'"'"'s'

    server-rolebinding.yaml
    '.subjects[0].namespace = "sandcastle-system"'
    'the server binding'"'"'s subject namespace is sandcastle-agents, not left to default elsewhere'

    server-rolebinding.yaml
    '.subjects[0].kind = "User"'
    'the server binding'"'"'s subject is a ServiceAccount, not a User or Group'

    server-rolebinding.yaml
    '.subjects += [{"kind": "ServiceAccount", "name": "sandcastle-agent", "namespace": "sandcastle-agents"}]'
    'the server binding grants exactly one subject'

    job.yaml
    '---
apiVersion: v1
kind: Pod
metadata:
  name: smuggled
  namespace: sandcastle-agents
spec:
  containers:
    - name: smuggled
      image: busybox'
    'a manifest holds one document, so nothing rides along behind the Job'

    extra.yml
    '---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stray
  namespace: sandcastle-agents
data:
  note: a manifest no assertion below ever reads'
    'every manifest in the directory is one the validator knows about'
)

PROVEN=0
INERT=0

log() {
    printf '[PROVE] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

requireTools() {
    command -v yq >/dev/null ||
        die "yq not found (brew install yq, or see deploy/kubernetes/README.md)"
}

# The manifests and the scripts travel together, so the copy validates itself: validate.sh
# resolves its manifests from its own location.
copyManifests() {
    local destination=$1
    cp -R "$MANIFEST_DIR/." "$destination/"
}

# Nothing is proven by a mutation failing validation if validation fails on the manifests as
# they stand, so establish that it does not.
proveControl() {
    local workDir=$1 copy="$1/control"

    mkdir -p "$copy"
    copyManifests "$copy"
    if "$copy/scripts/validate.sh" >/dev/null 2>&1; then
        log "control: the manifests as committed pass validation"
        return 0
    fi
    "$copy/scripts/validate.sh" >&2 || true
    die "the manifests as committed do not pass validation; nothing below would mean anything"
}

# A `---` mutation is appended verbatim, which turns a manifest into a two-document file, or
# creates one that was not there at all. Anything else is a yq expression.
applyMutation() {
    local file=$1 mutation=$2

    case $mutation in
        ---*) printf '%s\n' "$mutation" >>"$file" ;;
        *) yq -i "$mutation" "$file" ;;
    esac
}

# The assertion that caught the mutation is reported alongside it, so that a mutation which
# fails validation for some unrelated reason is visible as the false positive it is.
proveMutation() {
    local workDir=$1 index=$2 manifest=$3 expression=$4 property=$5 copy="$1/mutation-$2"
    local output status=0 caughtBy

    mkdir -p "$copy"
    copyManifests "$copy"
    applyMutation "$copy/$manifest" "$expression" || die "mutation $index could not be applied"

    output=$("$copy/scripts/validate.sh" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        INERT=$((INERT + 1))
        log "INERT: validation still passes without: $property"
        log "       ($manifest, $expression)"
        return 0
    fi

    PROVEN=$((PROVEN + 1))
    caughtBy=$(printf '%s\n' "$output" | grep -m1 'FAIL:' || true)
    log "proven: $property"
    log "        caught by: ${caughtBy#*FAIL: }"
}

main() {
    local workDir index=0 i

    requireTools

    workDir=$(mktemp -d)
    # shellcheck disable=SC2064 # $workDir is expanded now on purpose.
    trap "rm -rf '$workDir'" EXIT

    proveControl "$workDir"

    for ((i = 0; i < ${#MUTATIONS[@]}; i += 3)); do
        index=$((index + 1))
        proveMutation "$workDir" "$index" \
            "${MUTATIONS[i]}" "${MUTATIONS[i + 1]}" "${MUTATIONS[i + 2]}"
    done

    log "$PROVEN assertions proven to bite, $INERT inert"
    [ "$INERT" -eq 0 ] || exit 1
}

main "$@"
