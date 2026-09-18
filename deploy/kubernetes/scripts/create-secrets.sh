#!/usr/bin/env bash
# Creates the two Secrets an agent run needs (docs/ARCHITECTURE.md §14, §15, §36).
#
# Sand Castle knows a secret name, a key and a credential type; it never knows a value (§14).
# This script is the one place a value crosses from the operator's machine into the cluster, and
# the names and keys it writes are the contract job.yaml's `secretKeyRef` entries declare:
#
#   sandcastle-github-token / token   -> GITHUB_TOKEN
#   sandcastle-claude-oauth / token   -> CLAUDE_CODE_OAUTH_TOKEN
#
# The credential never reaches argv. `kubectl create secret generic --from-literal=token=$TOKEN`
# puts it in the process table, where any user on the machine can read it out of /proc/*/cmdline
# -- #2 lost a review round to exactly that, with a token in curl's `--header` -- and in the
# shell history of whoever ran the command. Here the value goes into a 0600 file inside a 0700
# temporary directory, `kubectl create` reads that file, and the rendered Secret reaches
# `kubectl apply` on stdin. Only the file's *path* is ever an argument.
#
# Usage:
#   export GITHUB_TOKEN=... CLAUDE_CODE_OAUTH_TOKEN=...   # or put them in images/.env.local
#   ./deploy/kubernetes/scripts/create-secrets.sh
#   ./deploy/kubernetes/scripts/create-secrets.sh --verify   # read the cluster, change nothing
#
# Re-running replaces both Secrets rather than failing, so this is also how a rotated credential
# is installed. No credential value is ever printed, by this script or by the kubectl it runs.

set -euo pipefail
# Tracing expands credential values into the trace, so keep it off however this was invoked
# (§14). The umask is the other half: the only file this script writes holds a credential, and
# `mktemp` honours the umask in force when it runs.
set +x
umask 077

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

readonly NAMESPACE="sandcastle-agents"

# secret name | key | environment variable | what it is, for the message naming a missing one.
# One entry per Secret. job.yaml is the other half of this contract, and secrets.bats compares
# the two, so neither side can drift alone.
readonly SECRET_SPECS=(
    "sandcastle-github-token|token|GITHUB_TOKEN|GitHub token the run clones and reads the issue with (§17)"
    "sandcastle-claude-oauth|token|CLAUDE_CODE_OAUTH_TOKEN|Claude Code OAuth token the CLI authenticates with (§13, §14)"
)

# The same git-ignored file images/agent/scripts/smoke.sh reads, in the same KEY=VALUE form. The
# override exists so the bats suite can never reach an operator's real one; an operator who
# keeps the file elsewhere can use it too. Neither the path nor the file is ever printed with a
# value beside it.
readonly CREDENTIAL_FILE="${SANDCASTLE_ENV_FILE:-$REPO_ROOT/images/.env.local}"

CREDENTIAL_DIR=
VERIFY_ONLY=no

# Credential values are never logged; only variable names, secret names and key names are (§14).
log() {
    printf '[SECRETS] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [--verify]

Creates (or replaces) the Secrets an agent run reads, in the $NAMESPACE namespace.

Credentials are read from the environment, or from $CREDENTIAL_FILE.
They are never accepted as arguments: an argument is visible in the process table.

  --verify   confirm the Secrets exist with the expected keys, and change nothing
  --help     this text
EOF
}

# An unrecognised argument is never echoed back. The mistake this guards against is someone
# typing a token where an option goes, and an error message that repeated it would put the
# credential in the terminal scrollback and the shell history this whole script exists to keep
# it out of.
parseArgs() {
    while [ $# -gt 0 ]; do
        case $1 in
            --verify) VERIFY_ONLY=yes ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                usage
                die "unrecognised argument (not shown -- it may be a credential); this script takes none"
                ;;
        esac
        shift
    done
}

# Splits one SECRET_SPECS entry into four globals, so every loop below reads the same four
# names rather than counting fields.
parseSpec() {
    IFS='|' read -r SPEC_NAME SPEC_KEY SPEC_VAR SPEC_DESCRIPTION <<<"$1"
}

requireKubectl() {
    command -v kubectl >/dev/null ||
        die "kubectl not found on PATH (see deploy/kubernetes/README.md)"
}

# The namespace is namespace.yaml's, with the Pod Security Admission labels §50 depends on.
# `kubectl create namespace` here would make one without them, so this refuses and names the
# manifest instead.
requireNamespace() {
    kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 ||
        die "namespace $NAMESPACE does not exist (kubectl apply -f deploy/kubernetes/namespace.yaml)"
}

# Reads the credential file, without letting it override what the operator just exported.
#
# The environment winning is the convention everywhere else a value can arrive twice in this
# repo (smoke.sh's own parseArgs and its own sourcing of this same file, render-job.sh), and it
# matters more here than anywhere else: this script writes to a cluster, so a stale line in
# .env.local silently beating an exported value would install yesterday's credential and say
# nothing about it. Save what the environment has, source, put it back.
sourceCredentialFile() {
    local spec saved

    [ -f "$CREDENTIAL_FILE" ] || return 0
    log "Reading credentials not already in the environment from $CREDENTIAL_FILE"

    for spec in "${SECRET_SPECS[@]}"; do
        parseSpec "$spec"
        printf -v "PRESET_$SPEC_VAR" '%s' "${!SPEC_VAR-}"
    done

    set -a
    # shellcheck source=/dev/null
    . "$CREDENTIAL_FILE"
    set +a

    for spec in "${SECRET_SPECS[@]}"; do
        parseSpec "$spec"
        saved="PRESET_$SPEC_VAR"
        [ -z "${!saved}" ] || printf -v "$SPEC_VAR" '%s' "${!saved}"
        unset "$saved"
    done
}

# Every missing credential in one message, so an operator with neither set is told both at once
# rather than one per run. Variable names and descriptions only -- never a value (§14).
requireCredentials() {
    local spec missing=()

    for spec in "${SECRET_SPECS[@]}"; do
        parseSpec "$spec"
        [ -n "${!SPEC_VAR-}" ] || missing+=("$SPEC_VAR ($SPEC_DESCRIPTION)")
    done

    [ ${#missing[@]} -eq 0 ] ||
        die "no credential for: ${missing[*]}. Export each one, or put it in $CREDENTIAL_FILE."
}

# Phase 1's first real run failed because CLAUDE_CODE_OAUTH_TOKEN held 2055 characters across 28
# lines -- the whole banner `claude setup-token` prints, pasted in place of the token inside it.
# A credential with a line break in it can never be valid, and neither can one carrying a space,
# a tab or a control character: every credential these CLIs take is a single run of printable,
# non-space characters. This is the same class of check #7 wants for GITHUB_TOKEN inside the
# container, so both variables get it, identically.
#
# The message names the variable, the defect, and the size of what was found -- "N characters
# across M lines" is what identifies the banner mistake at a glance -- and never the value.
requireWellFormedCredentials() {
    local spec value lines

    for spec in "${SECRET_SPECS[@]}"; do
        parseSpec "$spec"
        value=${!SPEC_VAR}

        case $value in
            *$'\n'* | *$'\r'*)
                lines=$(printf '%s\n' "$value" | wc -l | tr -d ' ')
                die "$SPEC_VAR contains a line break, so it cannot be a credential: ${#value} characters across $lines lines. \`claude setup-token\` prints a banner around the token; export the token alone. (The value is not shown.)"
                ;;
        esac

        # The pattern is the argument and the value is on stdin, here as everywhere else.
        if printf '%s' "$value" | LC_ALL=C grep -q '[^[:graph:]]'; then
            die "$SPEC_VAR contains whitespace or a control character, so it cannot be a credential: ${#value} characters. (The value is not shown.)"
        fi
    done

    log "Credentials validated by shape; no value was logged"
}

# One 0700 directory for the whole run, removed however this script leaves -- including on the
# `set -e` path out of a failed kubectl, and on a signal.
makeCredentialDir() {
    CREDENTIAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sandcastle-secrets.XXXXXX") ||
        die "could not create a temporary directory for the credentials"
    trap removeCredentialDir EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

removeCredentialDir() {
    [ -z "$CREDENTIAL_DIR" ] || rm -rf "$CREDENTIAL_DIR"
    CREDENTIAL_DIR=
}

# The value reaches the file through a builtin's output redirection, so it is not an argument of
# anything, and `printf '%s'` appends no newline: the file's bytes are the credential's bytes,
# which is what `--from-file` will store under the key.
writeCredentialFile() {
    local path="$CREDENTIAL_DIR/$1" var=$2

    printf '%s' "${!var}" >"$path"
    printf '%s' "$path"
}

# `--from-file=key=path` puts the path in argv and leaves the value in the file, which is the
# whole point. `--dry-run=client -o yaml | kubectl apply -f -` is what makes it idempotent --
# `create` alone fails on the second run -- and it keeps the rendered Secret on stdin rather
# than turning it into another argument.
applySecret() {
    local name=$1 key=$2 var=$3 path

    path=$(writeCredentialFile "$key" "$var")

    log "Applying secret $name (key $key) from $var in namespace $NAMESPACE"
    kubectl create secret generic "$name" \
        --namespace "$NAMESPACE" \
        --from-file="$key=$path" \
        --dry-run=client -o yaml |
        kubectl apply --namespace "$NAMESPACE" -f -
}

# Confirms what is in the cluster without reading a value out of it. The key names come from a
# go-template over `.data`, which prints the keys and not the values; the length is the decoded
# value piped straight into `wc -c`, counted and discarded without ever being printed or
# assigned. `-o jsonpath={.data.token}` would print the credential itself.
#
# Both templates below must stay *static*, and the reason is not tidiness. When a go-template
# fails at execution time -- an `index` into something that is not a map, a method call on a
# missing field -- kubectl does not merely report the error: it prints `raw data was: {...}`,
# the whole object it was rendering, which for a Secret is every key and its base64-encoded
# value. It does that on stderr and **exits 0**. The first call captures stderr into $keys and
# reports it in the failure message, so a template that can fail turns this verify path into a
# credential dump in a log the operator is likely to paste somewhere; the second call would
# pipe the dump into `wc -c`, which is harmless only by luck of where it goes.
#
# Neither fixed template can reach that: ranging over an absent or empty `.data` yields the
# empty string cleanly, which is the "(none)" case below, and `index` on a key checked to exist
# a moment earlier cannot fail. Interpolating anything an operator or a caller controls into
# either one removes that guarantee. If a dynamic template ever becomes necessary, keep
# kubectl's stderr out of the message rather than trusting the template.
verifySecret() {
    local name=$1 key=$2 keys bytes

    # shellcheck disable=SC2016 # $k and $v are go-template variables, not shell ones.
    keys=$(kubectl get secret "$name" --namespace "$NAMESPACE" \
        -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1) ||
        die "secret $name is not readable in namespace $NAMESPACE: $keys"

    keys=${keys% }
    [ "$keys" = "$key" ] ||
        die "secret $name should hold exactly the key '$key', and holds: ${keys:-(none)}"

    bytes=$(kubectl get secret "$name" --namespace "$NAMESPACE" \
        -o go-template="{{index .data \"$key\" | base64decode}}" | wc -c | tr -d ' ')
    [ "$bytes" -gt 0 ] ||
        die "secret $name holds an empty value under '$key', which is #14's failure exactly"

    log "$name: key '$key' present, $bytes bytes (value not shown)"
}

forEachSecret() {
    local action=$1 spec

    for spec in "${SECRET_SPECS[@]}"; do
        parseSpec "$spec"
        "$action" "$SPEC_NAME" "$SPEC_KEY" "$SPEC_VAR"
    done
}

verifyOnly() {
    requireKubectl
    requireNamespace
    forEachSecret verifySecret
    log "Both Secrets are present with the keys job.yaml expects"
}

createSecrets() {
    # Credentials first and the cluster second: with none set this exits before kubectl is
    # invoked at all, which the suite asserts rather than hopes for.
    sourceCredentialFile
    requireCredentials
    requireWellFormedCredentials

    requireKubectl
    requireNamespace

    makeCredentialDir
    forEachSecret applySecret
    removeCredentialDir

    forEachSecret verifySecret
    log "Done. The values are now in the operator's environment and in the cluster, nowhere else."
}

main() {
    parseArgs "$@"

    if [ "$VERIFY_ONLY" = yes ]; then
        verifyOnly
    else
        createSecrets
    fi
}

main "$@"
