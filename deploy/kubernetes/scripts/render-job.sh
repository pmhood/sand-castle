#!/usr/bin/env bash
# Renders job.yaml for one run (docs/ARCHITECTURE.md §19, §20, §36).
#
# job.yaml carries three `${...}` placeholders and nothing else that varies. This substitutes
# them, validates each value first, and writes the result to stdout. It is the only renderer on
# this side: the README's manual Phase 2 flow, scripts/launch-run.sh and scripts/validate.sh all
# go through it, so there is one answer to "what does an applied Job look like".
#
# It is no longer the only renderer in the repository. Phase 3's server builds the same manifest
# in TypeScript (apps/server/src/kubernetes/job-builder.ts, #52), because a server that has to
# submit a Job to the API server has no use for rendered YAML, and an operator with no server
# running has no use for a TypeScript build. The two are kept honest by
# apps/server/test/kubernetes/job-builder.test.ts, which runs *this script* and requires what it
# prints to equal what the builder returns -- so a change to job.yaml that is not also made there
# fails the server's test suite. Read that file's header for the decision and the plan to
# converge; do not edit job.yaml on the assumption that it is still the only copy.
#
# Usage:
#   ./deploy/kubernetes/scripts/render-job.sh <run-id> <owner/repo> <issue-number>
#   RUN_ID=run-001 GITHUB_REPOSITORY=owner/repo GITHUB_ISSUE_NUMBER=7 ./…/render-job.sh
#
#   ./deploy/kubernetes/scripts/render-job.sh run-001 octocat/Hello-World 1 | kubectl apply -f -
#
# No credential is an input here, and none appears in the output: credentials reach the Pod
# only through the secretKeyRef entries job.yaml already carries (§15, §52).

set -euo pipefail
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly MANIFEST_DIR="$(dirname "$SCRIPT_DIR")"

# `sandcastle-<run-id>` must be a DNS-1123 label, and a label value, so at most 63 characters.
readonly RUN_ID_MAX_LENGTH=52

log() {
    printf '[RENDER] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# The environment takes precedence over the arguments, as in images/agent/scripts/smoke.sh.
parseArgs() {
    RUN_ID=${RUN_ID:-${1-}}
    GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-${2-}}
    GITHUB_ISSUE_NUMBER=${GITHUB_ISSUE_NUMBER:-${3-}}
}

# An empty value must never be substituted. A Job with an empty run ID is not merely wrong, it
# is a Job named `sandcastle-` that the API server rejects at best and that collides with the
# next empty one at worst -- the same class of mistake as #14's empty credential variable.
validateArgs() {
    [[ -n $RUN_ID ]] || die "run ID not set (usage: $0 <run-id> <owner/repo> <issue-number>)"
    [[ -n $GITHUB_REPOSITORY ]] || die "repository not set (usage: $0 <run-id> <owner/repo> <issue-number>)"
    [[ -n $GITHUB_ISSUE_NUMBER ]] || die "issue number not set (usage: $0 <run-id> <owner/repo> <issue-number>)"

    [[ $RUN_ID =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
        die "run ID '$RUN_ID' is not a DNS-1123 label (lower-case letters, digits and hyphens)"
    [[ ${#RUN_ID} -le $RUN_ID_MAX_LENGTH ]] ||
        die "run ID '$RUN_ID' is longer than $RUN_ID_MAX_LENGTH characters"
    [[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die "repository '$GITHUB_REPOSITORY' is not owner/repo"
    [[ $GITHUB_ISSUE_NUMBER =~ ^[1-9][0-9]*$ ]] ||
        die "issue number '$GITHUB_ISSUE_NUMBER' is not a positive integer"
}

# Substitution is a plain sed rather than envsubst: envsubst is not installed everywhere, and
# it would also expand anything else that ever comes to look like a shell variable in the
# manifest. Every value reaching sed here has been matched against a fixed character set above,
# so none of them can carry a delimiter or a backreference.
renderJob() {
    sed \
        -e "s|\${RUN_ID}|$RUN_ID|g" \
        -e "s|\${GITHUB_REPOSITORY}|$GITHUB_REPOSITORY|g" \
        -e "s|\${GITHUB_ISSUE_NUMBER}|$GITHUB_ISSUE_NUMBER|g" \
        "$MANIFEST_DIR/job.yaml"
}

# A placeholder added to job.yaml but not here would otherwise be applied literally, and
# `${SOMETHING}` is a perfectly valid YAML string that no schema check would object to.
# Whole-line comments are exempt: job.yaml's own header explains the placeholders by name.
assertFullyRendered() {
    local rendered=$1 leftovers

    # shellcheck disable=SC2016 # `${` is the literal text being searched for, not an expansion.
    leftovers=$(printf '%s\n' "$rendered" | grep -vn '^[[:space:]]*#' | grep -F '${' || true)
    [[ -z $leftovers ]] || {
        printf '%s\n' "$leftovers" >&2
        die "job.yaml still contains a placeholder this renderer does not substitute"
    }
}

main() {
    local rendered

    parseArgs "$@"
    validateArgs

    rendered=$(renderJob)
    assertFullyRendered "$rendered"

    printf '%s\n' "$rendered"
}

main "$@"
