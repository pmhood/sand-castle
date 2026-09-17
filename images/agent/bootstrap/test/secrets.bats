#!/usr/bin/env bats
# deploy/kubernetes/scripts/create-secrets.sh: the two Secrets an agent run reads
# (docs/ARCHITECTURE.md §14, §15, §36).
#
# The property this file exists for is the one #2 lost a review round to: a credential passed as
# a command-line argument is readable from the process table by every user on the machine, and
# `kubectl create secret generic --from-literal=token=$TOKEN` is that bug in Kubernetes
# clothing. helpers.bash binds a recording `kubectl` at load time -- so no test here can reach a
# cluster -- and it records what reached argv apart from what reached stdin, which is the whole
# distinction. The canary assertions below read the argv record; "the argv record catches a
# --from-literal" is what proves that record is not empty for some unrelated reason.
#
# Values are obviously-fake canaries, distinct per variable, so no single one can regress
# unnoticed behind another.

bats_require_minimum_version 1.5.0

load helpers

REPO_ROOT="$(cd "$(dirname "$BOOTSTRAP_DIR")/../.." && pwd)"
SECRETS_SCRIPT="$REPO_ROOT/deploy/kubernetes/scripts/create-secrets.sh"
JOB_MANIFEST="$REPO_ROOT/deploy/kubernetes/job.yaml"

readonly CANARY_GITHUB='canary-github-1f7c0d'
readonly CANARY_OAUTH='canary-oauth-4b9e22'

setup() {
    # The operator's real images/.env.local must never be reachable from a test: it holds real
    # credentials, and a test that read them would hand them to the recording kubectl and write
    # them into a temporary file. Every test points the script at a path of its own instead,
    # which does not exist unless the test writes it.
    export SANDCASTLE_ENV_FILE="$BATS_TEST_TMPDIR/env.local"
}

# Runs the script the way an operator does: credentials in the environment, never in argv.
runWithCanaries() {
    run bash -c "
        export GITHUB_TOKEN='$CANARY_GITHUB' CLAUDE_CODE_OAUTH_TOKEN='$CANARY_OAUTH'
        '$SECRETS_SCRIPT' $* 2>&1
    "
}

# Everything the script put in argv, across every kubectl invocation, in both of the forms the
# fake records it: one argument per line, and one whole command line per line.
recordedArgv() {
    cat "$KUBECTL_RECORD/argv" "$KUBECTL_RECORD/commands"
}

# secret/key pairs the run actually created, read back out of the fake's store.
createdSecretRefs() {
    local dir key
    for dir in "$KUBECTL_RECORD"/store/*/; do
        for key in "$dir"*; do
            printf '%s/%s\n' "$(basename "$dir")" "$(basename "$key")"
        done
    done | sort
}

# secret/key pairs job.yaml requires, read out of its secretKeyRef entries.
requiredSecretRefs() {
    awk '/secretKeyRef:/ { inRef = 1; name = ""; next }
         inRef && $1 == "name:" { name = $2; next }
         inRef && $1 == "key:" { print name "/" $2; inRef = 0 }' "$JOB_MANIFEST" | sort
}

@test "the script and the manifest this suite cross-checks are both present" {
    # A wrong volume mount is the way this file silently stops testing anything: in-container
    # runs mount the repository root for exactly this reason (images/agent/README.md). Failing
    # here says so, where a missing-file error inside a `run` would read as a script bug.
    [ -x "$SECRETS_SCRIPT" ]
    [ -f "$JOB_MANIFEST" ]
}

@test "with no credentials it fails naming both, and never invokes kubectl" {
    run bash -c "unset GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN; '$SECRETS_SCRIPT' 2>&1"
    [ "$status" -ne 0 ]
    assertContains "$output" 'GITHUB_TOKEN' 'CLAUDE_CODE_OAUTH_TOKEN'
    # Validation runs before the cluster is touched, so there is no record at all.
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

@test "with one credential set it names the one that is missing" {
    run bash -c "
        unset CLAUDE_CODE_OAUTH_TOKEN
        export GITHUB_TOKEN='$CANARY_GITHUB'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -ne 0 ]
    assertContains "$output" 'CLAUDE_CODE_OAUTH_TOKEN'
    refuteContains "$output" "$CANARY_GITHUB"
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

# Phase 1's first real run failed on a CLAUDE_CODE_OAUTH_TOKEN holding the whole banner
# `claude setup-token` prints -- 2055 characters across 28 lines -- rather than the token in it.
@test "a credential containing a line break is refused before anything reaches the cluster" {
    run bash -c "
        export GITHUB_TOKEN='$CANARY_GITHUB'
        export CLAUDE_CODE_OAUTH_TOKEN='banner line
$CANARY_OAUTH
more banner'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -ne 0 ]
    assertLineContains "$output" 'CLAUDE_CODE_OAUTH_TOKEN' 'line break'
    # The message says how much was found, and never what it was.
    assertContains "$output" '3 lines'
    refuteContains "$output" "$CANARY_OAUTH"
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

# #7 is the same defect class for GITHUB_TOKEN, so the two are checked identically; a rule that
# held for one credential and not the other would be worth less than no rule.
@test "the line-break rule applies to GITHUB_TOKEN too" {
    run bash -c "
        export CLAUDE_CODE_OAUTH_TOKEN='$CANARY_OAUTH'
        export GITHUB_TOKEN='$CANARY_GITHUB
trailing junk'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -ne 0 ]
    assertLineContains "$output" 'GITHUB_TOKEN' 'line break'
    refuteContains "$output" "$CANARY_GITHUB"
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

@test "a credential containing a space is refused, and its value is not echoed" {
    run bash -c "
        export GITHUB_TOKEN='$CANARY_GITHUB'
        export CLAUDE_CODE_OAUTH_TOKEN='Bearer $CANARY_OAUTH'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -ne 0 ]
    assertLineContains "$output" 'CLAUDE_CODE_OAUTH_TOKEN' 'whitespace'
    refuteContains "$output" "$CANARY_OAUTH"
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

@test "no credential value reaches kubectl's argv, and each one does reach it by file" {
    runWithCanaries
    [ "$status" -eq 0 ]

    # The negative: nothing that was passed as an argument, in either record of argv.
    [ -f "$KUBECTL_RECORD/argv" ]
    run recordedArgv
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"

    # The positive, without which the negative could be satisfied by a script that passed no
    # credential anywhere: each value did reach kubectl, as the contents of the file named by
    # --from-file, and came out the far end of the pipe into `apply` as the Secret's data.
    run cat "$KUBECTL_RECORD/store/sandcastle-github-token/token"
    assertContains "$output" "$CANARY_GITHUB"
    run cat "$KUBECTL_RECORD/store/sandcastle-claude-oauth/token"
    assertContains "$output" "$CANARY_OAUTH"

    run cat "$KUBECTL_RECORD/stdin"
    assertContains "$output" \
        "$(printf '%s' "$CANARY_GITHUB" | base64 | tr -d '\n')" \
        "$(printf '%s' "$CANARY_OAUTH" | base64 | tr -d '\n')"
}

@test "no credential value appears in the script's own output" {
    runWithCanaries
    [ "$status" -eq 0 ]
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"
    # It still says what it did, by name.
    assertContains "$output" 'sandcastle-github-token' 'sandcastle-claude-oauth'
}

@test "the value travels as a file path: --from-file, never --from-literal" {
    runWithCanaries
    [ "$status" -eq 0 ]

    run grep -c -- '--from-file=token=' "$KUBECTL_RECORD/argv"
    [ "$output" -eq 2 ]
    run grep -c -- '--from-literal' "$KUBECTL_RECORD/argv"
    [ "$status" -ne 0 ]
}

# The check on the check. Every assertion above reads $KUBECTL_RECORD/argv, and all of them
# would pass just as well against a fake that recorded nothing -- which is the shape of mistake
# #8's audit found 49 of. This is `--from-file` switched for the `--from-literal` the issue
# warns about, run against the same fake: the canary lands in the argv record, so the record
# does hold what a process table would have shown, and the refutations above can fail.
@test "the argv record is real: a --from-literal invocation puts the value in argv" {
    run kubectl create secret generic sandcastle-proof \
        --namespace sandcastle-agents \
        --from-literal=token=canary-literal-90ab3f \
        --dry-run=client -o yaml
    [ "$status" -eq 0 ]

    run recordedArgv
    assertContains "$output" 'canary-literal-90ab3f'
}

@test "the Secrets created are exactly the ones job.yaml's secretKeyRef entries require" {
    runWithCanaries
    [ "$status" -eq 0 ]

    # Both sides are computed, neither is a literal: if #19's manifest renames a Secret or a
    # key, this fails rather than leaving a Job that cannot start.
    local required created
    required=$(requiredSecretRefs)
    created=$(createdSecretRefs)
    [ -n "$required" ]
    assertContains "$created" "$required"
    [ "$created" = "$required" ]
}

@test "running twice succeeds and leaves one Secret of each kind, holding the newer value" {
    runWithCanaries
    [ "$status" -eq 0 ]

    # A rotation: the same two Secrets, different values. `create` alone would fail here with
    # AlreadyExists, which is what the --dry-run-and-apply pipeline is for. Only the real
    # cluster can show the API server refusing the second `create`; what this shows is that the
    # script's second run succeeds and replaces rather than accumulating.
    run bash -c "
        export GITHUB_TOKEN='${CANARY_GITHUB}-rotated' CLAUDE_CODE_OAUTH_TOKEN='${CANARY_OAUTH}-rotated'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -eq 0 ]

    local created
    created=$(createdSecretRefs)
    [ "$created" = "$(requiredSecretRefs)" ]

    run cat "$KUBECTL_RECORD/store/sandcastle-claude-oauth/token"
    assertContains "$output" "${CANARY_OAUTH}-rotated"
}

@test "the file the credential passed through is removed, and so is its directory" {
    runWithCanaries
    [ "$status" -eq 0 ]

    # The paths kubectl was given. Nothing may survive the run at any of them.
    local path
    while IFS= read -r path; do
        [ ! -e "$path" ]
        [ ! -d "$(dirname "$path")" ]
    done <"$KUBECTL_RECORD/from-file.paths"
    [ -s "$KUBECTL_RECORD/from-file.paths" ]
}

@test "--verify reports the keys and the lengths, and no value" {
    runWithCanaries
    [ "$status" -eq 0 ]

    run bash -c "unset GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN; '$SECRETS_SCRIPT' --verify 2>&1"
    [ "$status" -eq 0 ]
    assertLineContains "$output" 'sandcastle-github-token' "key 'token' present" "${#CANARY_GITHUB} bytes"
    assertLineContains "$output" 'sandcastle-claude-oauth' "key 'token' present" "${#CANARY_OAUTH} bytes"
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"
}

@test "--verify fails when a Secret is missing, and creates nothing" {
    run bash -c "'$SECRETS_SCRIPT' --verify 2>&1"
    [ "$status" -ne 0 ]
    assertContains "$output" 'sandcastle-github-token'
    [ ! -d "$KUBECTL_RECORD/store/sandcastle-github-token" ]
}

@test "it refuses to create anything when the namespace does not exist" {
    run bash -c "
        export KUBECTL_FAKE_NAMESPACE_MISSING=yes
        export GITHUB_TOKEN='$CANARY_GITHUB' CLAUDE_CODE_OAUTH_TOKEN='$CANARY_OAUTH'
        '$SECRETS_SCRIPT' 2>&1
    "
    [ "$status" -ne 0 ]
    # It names the manifest rather than creating an unlabelled namespace of its own (§50).
    assertContains "$output" 'namespace.yaml'
    [ ! -d "$KUBECTL_RECORD/store/sandcastle-github-token" ]
    [ ! -f "$KUBECTL_RECORD/from-file.token" ]
}

@test "an argument is refused without being echoed, credential-shaped or not" {
    run bash -c "
        export GITHUB_TOKEN='$CANARY_GITHUB' CLAUDE_CODE_OAUTH_TOKEN='$CANARY_OAUTH'
        '$SECRETS_SCRIPT' '$CANARY_OAUTH' 2>&1
    "
    [ "$status" -ne 0 ]
    # The mistake being guarded is a token typed where an option goes; repeating it in the
    # error would put it in the scrollback and the shell history this script exists to avoid.
    refuteContains "$output" "$CANARY_OAUTH"
    assertContains "$output" 'unrecognised argument'
    [ ! -f "$KUBECTL_RECORD/argv" ]
}

@test "a credential in the credential file is used when the environment has none" {
    printf "GITHUB_TOKEN='%s'\nCLAUDE_CODE_OAUTH_TOKEN='%s'\n" \
        "$CANARY_GITHUB" "$CANARY_OAUTH" >"$SANDCASTLE_ENV_FILE"

    run bash -c "unset GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN; '$SECRETS_SCRIPT' 2>&1"
    [ "$status" -eq 0 ]
    refuteContains "$output" "$CANARY_GITHUB" "$CANARY_OAUTH"

    run cat "$KUBECTL_RECORD/store/sandcastle-claude-oauth/token"
    assertContains "$output" "$CANARY_OAUTH"
}

# The one deliberate divergence from smoke.sh, which sources the file over the top of the
# environment. This script writes to a cluster, so a stale line in the file silently beating
# what the operator just exported would install yesterday's credential and say nothing.
@test "an exported credential wins over the credential file" {
    printf "GITHUB_TOKEN='%s'\nCLAUDE_CODE_OAUTH_TOKEN='%s'\n" \
        "stale-github-000000" "stale-oauth-000000" >"$SANDCASTLE_ENV_FILE"

    runWithCanaries
    [ "$status" -eq 0 ]

    run cat "$KUBECTL_RECORD/store/sandcastle-github-token/token"
    assertContains "$output" "$CANARY_GITHUB"
    refuteContains "$output" 'stale-github-000000'
    run cat "$KUBECTL_RECORD/store/sandcastle-claude-oauth/token"
    assertContains "$output" "$CANARY_OAUTH"
    refuteContains "$output" 'stale-oauth-000000'
}

@test "create-secrets.sh is valid bash syntax" {
    bash -n "$SECRETS_SCRIPT"
}
