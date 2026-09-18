#!/usr/bin/env bash
# Checks every jsonpath in launch-run.sh and probe-nodes.sh against the cluster's own schema
# (#28, docs/ARCHITECTURE.md §36).
#
# `kubectl -o jsonpath` answers a field that does not exist with an empty string and exit 0.
# Nothing says the query was wrong. launch-run.sh reads that empty answer as a Pod that reported
# nothing, which is a run it cannot classify -- so one mistyped field path turns §36's whole
# value, naming the layer that broke, into a confidently generic message. It fails in the
# direction that looks fine from a desk: there is no cluster in CI to answer any differently.
#
# The bats suite catches a typo offline, because its fake kubectl refuses a query it was never
# taught (images/agent/bootstrap/test/launch.bats). That half is fast, needs nothing, and is a
# mirror: the fake and the queries agree because the same hand wrote both, so what it proves is
# that nobody has changed one of them since. This half asks something that is not us -- the API
# server's own schema, through `kubectl explain` -- and it is the only one that notices a field
# Kubernetes renamed or removed underneath a query that still reads correctly.
#
# It needs a cluster, so it cannot be a required CI check. Run it after a Kubernetes upgrade and
# whenever a query changes. `--list` needs no cluster and prints what would be checked.
#
# What it does not check is the launcher's other reading of Kubernetes: the prose. Every
# classifier branch matches words the kubelet and containerd chose -- `no match for platform`,
# `failed to authorize` -- and no schema describes those. That is a known and accepted gap;
# deploy/kubernetes/README.md, "What these checks do not cover", says why.
#
# Usage:
#   ./deploy/kubernetes/scripts/check-jsonpath.sh
#   ./deploy/kubernetes/scripts/check-jsonpath.sh --list

set -euo pipefail
# Tracing is off however this was invoked, as in every script here (§14).
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The two scripts that read the cluster through jsonpath. create-secrets.sh is not one of them:
# it reads a Secret through a go-template, deliberately, because a jsonpath over `.data` would
# print the credential (see the note above verifySecret there).
readonly SOURCES=("$SCRIPT_DIR/launch-run.sh" "$SCRIPT_DIR/probe-nodes.sh")

LIST_ONLY=no
CHECKED=0
FAILED=0

# §31's shape, with this script's own prefix, as the other scripts here have theirs.
log() {
    printf '[JSONPATH] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [--list]

Checks every field path the jsonpath queries in launch-run.sh and probe-nodes.sh ask for
against the cluster's schema, with \`kubectl explain\`. A field that is not there is answered
by a real cluster with an empty string and exit 0, which is silent everywhere else (#28).

  --list   print the resource and field path of every query and exit, without a cluster.

Needs a cluster, so it is not a CI check. See deploy/kubernetes/README.md, "Checking the
jsonpath queries".
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
            --list) LIST_ONLY=yes ;;
            *)
                log "ERROR: unknown argument '$arg'"
                usage
                exit 1
                ;;
        esac
    done
}

# Every `-o jsonpath=...` a script makes, as `resource<TAB>query`.
#
# The resource comes from the same kubectl invocation, which is why continuation lines are
# joined first: `kubectl get nodes -l ... \` and the `-o jsonpath=` under it are one command and
# have to be read as one. Everything is matched literally rather than by shell parsing -- these
# are two files in this directory, not arbitrary scripts.
#
# The resource is passed on as the script wrote it, `node` or `nodes`; `kubectl explain` takes
# either, and rewriting it here would be this script guessing at plurals for no gain.
queriesIn() {
    awk '
        { buffer = buffer $0 }
        /\\$/ { sub(/\\$/, " ", buffer); next }
        {
            line = buffer
            buffer = ""
            if (line ~ /^[[:space:]]*#/) next
            if (!match(line, /get [a-z]+/)) next
            resource = substr(line, RSTART + 4, RLENGTH - 4)
            start = index(line, "-o jsonpath=\047")
            if (start == 0) next
            query = substr(line, start + 13)
            stop = index(query, "\047")
            if (stop == 0) next
            print resource "\t" substr(query, 1, stop - 1)
        }
    ' "$1"
}

# One jsonpath segment as a path into the resource's own schema, or empty if nothing of it is
# one. Three things are removed, and each would make `kubectl explain` answer about a field that
# was never asked for:
#
#   a subscript   `[*]`, `[-1:]`, `[?(@.type=="PodScheduled")]` select among the values of a
#                 field; they do not name one.
#   `items`       belongs to the List a collection query returns, not to the Pod or Node in it.
#   a map key     `metadata.annotations.sandcastle\.dev/agent-capable-image` is an entry in a
#                 map, and the schema stops at the map. jsonpath escapes a dot only inside a
#                 key, so the escape is what marks where to stop.
schemaPath() {
    printf '%s' "$1" | awk '{
        path = $0
        gsub(/\[[^]]*\]/, "", path)
        sub(/^\./, "", path)
        sub(/^items(\.|$)/, "", path)
        n = split(path, part, ".")
        out = ""
        for (i = 1; i <= n; i++) {
            if (part[i] ~ /\\$/ || part[i] ~ /\//) break
            out = (out == "" ? part[i] : out "." part[i])
        }
        print out
    }'
}

# The field paths one query asks for, one per line. `{range X}` opens a prefix every segment up
# to `{end}` is relative to, and a segment that begins with a quote is a literal the query joins
# fields with rather than a field at all.
#
# A filter names a field of its own -- the `type` in `conditions[?(@.type=="PodScheduled")]` --
# and a typo there returns empty exactly like any other, so it is checked too.
fieldPaths() {
    local rest=$1 segment prefix='' path head filter

    while :; do
        case $rest in
            *'{'*) ;;
            *) break ;;
        esac
        rest=${rest#*\{}
        segment=${rest%%\}*}
        rest=${rest#*\}}

        case $segment in
            '' | '"'*) continue ;;
            end)
                prefix=''
                continue
                ;;
            'range '*)
                prefix=$(schemaPath "${segment#range }")
                continue
                ;;
            *'[?(@.'*)
                head=${segment%%'[?(@.'*}
                filter=${segment#*'[?(@.'}
                filter=${filter%%[!A-Za-z0-9_]*}
                emitPath "$prefix" "$head.$filter"
                ;;
        esac

        emitPath "$prefix" "$segment"
    done
}

emitPath() {
    local path
    path=$(schemaPath "$2")
    [ -n "$path" ] || return 0
    [ -z "$1" ] || path="$1.$path"
    printf '%s\n' "$path"
}

# Every field path both scripts ask for, as `resource.path`, once each.
allFieldPaths() {
    local source resource query path found=0

    for source in "${SOURCES[@]}"; do
        [ -f "$source" ] || die "$source is not there"
        while IFS=$'\t' read -r resource query; do
            found=$((found + 1))
            while IFS= read -r path; do
                printf '%s.%s\n' "$resource" "$path"
            done < <(fieldPaths "$query")
        done < <(queriesIn "$source")
    done

    # An extractor that reads nothing reports a clean run, which is the shape of check #8 found
    # 49 of. These two scripts have queries in them; finding none means this stopped working.
    [ "$found" -gt 0 ] || die "no jsonpath query found in ${SOURCES[*]}, so nothing was checked"
}

requireCluster() {
    command -v kubectl >/dev/null ||
        die "kubectl is not on PATH (see deploy/kubernetes/README.md)"
    # `explain` reads the schema from the API server, so this is the same question as "is there
    # a cluster", asked in the form the check itself uses.
    kubectl explain pod >/dev/null 2>&1 ||
        die "kubectl explain cannot reach a cluster; this check needs one (--list does not)"
}

main() {
    local paths path

    parseArgs "$@"
    paths=$(allFieldPaths | sort -u)

    if [ "$LIST_ONLY" = yes ]; then
        printf '%s\n' "$paths"
        log "$(printf '%s\n' "$paths" | wc -l | tr -d ' ') field paths, unchecked (--list)"
        return 0
    fi

    requireCluster
    while IFS= read -r path; do
        CHECKED=$((CHECKED + 1))
        if kubectl explain "$path" >/dev/null 2>&1; then
            continue
        fi
        FAILED=$((FAILED + 1))
        log "NOT IN THE SCHEMA: $path"
    done <<<"$paths"

    if [ "$FAILED" -gt 0 ]; then
        log "$FAILED of $CHECKED field paths are not in this cluster's schema"
        log "  A query asking for one of them returns an empty string and exit 0, so the run"
        log "  it was meant to classify is reported as one nothing could be learned about."
        exit 1
    fi
    log "$CHECKED field paths, all in this cluster's schema"
}

main "$@"
