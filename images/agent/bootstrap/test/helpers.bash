# Shared setup for the sandcastle-run test suite.

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDCASTLE_RUN="$BOOTSTRAP_DIR/sandcastle-run"

# A token value that must never reach stdout, stderr or the checkout (§14).
readonly FAKE_TOKEN='fake-token-3f8b21c7'

# The agent CLI's own credential: the runner must hand it to the CLI and never log it (§13).
readonly FAKE_AGENT_CREDENTIAL='fake-agent-credential-9d4e71a2'

# Neutralize the GitHub Actions environment so the test suite is hermetic.
# CI sets GITHUB_REPOSITORY, GITHUB_SERVER_URL, and GITHUB_API_URL; tests rely on these
# being absent so they can exercise different configurations. Unset them now so all tests
# inherit a clean slate, then each test can set them explicitly.
unset GITHUB_REPOSITORY GITHUB_ISSUE_NUMBER GITHUB_TOKEN GITHUB_SERVER_URL GITHUB_API_URL

# The developer's own agent credentials are neutralized for the same reason, and one more: a
# test that asserts the harness accepts ANTHROPIC_API_KEY passes without proving anything if the
# variable was already in the environment, and a real credential inherited from the developer's
# shell would be handed to the stand-in CLIs below and recorded in a temporary file (§14).
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
    CODEX_API_KEY CODEX_ACCESS_TOKEN CLAUDE_CONFIG_DIR CODEX_HOME

# A local git host and GitHub API stand-in, so the suite needs no network and no credential.
# file:// URLs exercise the same clone and curl code paths the real hosts do.
makeFixtures() {
    local root=$1 seed="$1/seed"

    mkdir -p "$root/octo" "$root/api/repos/octo/demo/issues"
    git init --quiet --initial-branch main "$seed"
    printf 'demo\n' >"$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" -c user.name=Fixture -c user.email=fixture@example.com \
        commit --quiet -m 'Initial commit'
    git clone --quiet --bare "$seed" "$root/octo/demo.git"

    cat >"$root/api/repos/octo/demo/issues/7" <<'JSON'
{
  "number": 7,
  "title": "Add authentication middleware",
  "body": "Sessions must expire after 30 minutes.",
  "labels": [{ "name": "bug" }, { "name": "effort:medium" }]
}
JSON

    # Issue 8 is what a proxy or an error page returns with a 200: a body that is not JSON.
    printf '<html>upstream proxy error</html>\n' >"$root/api/repos/octo/demo/issues/8"
}

# Exports a complete, valid environment pointed at the fixtures in $1.
exportRunEnvironment() {
    local root=$1

    export SANDCASTLE_RUN_ID=run-abc123
    export GITHUB_REPOSITORY=octo/demo
    export GITHUB_ISSUE_NUMBER=7
    export AGENT=claude
    export GITHUB_TOKEN=$FAKE_TOKEN
    export GITHUB_SERVER_URL="file://$root"
    export GITHUB_API_URL="file://$root/api"
    export SANDCASTLE_WORKSPACE="$root/workspace"
}

# Runs the bootstrap as the container does: as an executable, not a sourced library.
runBootstrap() {
    run "$SANDCASTLE_RUN" "$@"
}

# A run clones into a directory it expects to be empty, so a test that runs the bootstrap a
# second time -- once per agent, say -- has to give it a fresh workspace first.
resetWorkspace() {
    rm -rf "$SANDCASTLE_WORKSPACE"
}

# Puts fake `claude` and `codex` binaries on PATH. Each records how it was called -- its
# arguments, the prompt it read from stdin, its working directory and the credential it was
# handed -- writes a line to stdout and one to stderr, then exits with AGENT_CLI_EXIT. The
# suite can therefore exercise a whole run without a credential, a network or a real agent.
#
# Called at the bottom of this file rather than from a setup(), so that loading this file is
# itself what puts the stand-ins on PATH: every file in the suite loads it, and the stand-ins
# are in place before setup_file, setup and every test body. That is a convention, not a
# guarantee -- a file that reached sandcastle-run without loading this one would run against
# whatever `claude` the developer has on PATH -- so keep `load helpers` in every test file.
installFakeAgentClis() {
    local root bin name credentialVar

    # bats runs three kinds of pass, and the directory to use differs: gathering test names
    # (neither variable set, and no test code to protect), setup_file/teardown_file (only
    # BATS_FILE_TMPDIR, and they can call the bootstrap), and a test body (both set).
    root=${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR-}}
    [[ -n $root ]] || return 0
    bin="$root/bin"
    AGENT_CLI_RECORD="$root/agent-cli"
    mkdir -p "$bin" "$AGENT_CLI_RECORD"

    for name in claude codex; do
        # The credential each CLI actually reads from its environment; see bootstrap/runners/.
        case $name in
            claude) credentialVar=CLAUDE_CODE_OAUTH_TOKEN ;;
            codex) credentialVar=CODEX_API_KEY ;;
        esac
        cat >"$bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >'$AGENT_CLI_RECORD/$name.argv'
printf '%s\n' "\$PWD" >'$AGENT_CLI_RECORD/$name.cwd'
printf '%s' "\${$credentialVar-}" >'$AGENT_CLI_RECORD/$name.credential'
cat >'$AGENT_CLI_RECORD/$name.prompt'
printf 'fake $name read the prompt\n'
printf 'fake $name wrote to stderr\n' >&2
exit "\${AGENT_CLI_EXIT:-0}"
EOF
        chmod +x "$bin/$name"
    done

    export AGENT_CLI_EXIT=0
    export PATH="$bin:$PATH"
}

# Assertions. bash 3.2 -- what macOS ships, and therefore what `make test` runs on a developer
# machine -- does not apply errexit to a bare `[[ ]]`, so a `[[ ]]` assertion that is not the
# last command of its test body is a silent no-op there while bash 5 fails the test on it. Every
# assertion in this suite therefore either is a simple command (`[ ... ]`, which both shells
# honour) or goes through one of the helpers below, which return 1 explicitly. style.bats keeps
# it that way.
#
# The text to search is passed in rather than taken from $output, because a test asserts about
# $output, about $stderr when it asked for them apart, and about files the run wrote.
assertContains() {
    local text=$1 needle
    shift
    for needle in "$@"; do
        [[ $text == *"$needle"* ]] || {
            printf 'expected to find: %s\nin:\n%s\n' "$needle" "$text"
            return 1
        }
    done
}

refuteContains() {
    local text=$1 needle
    shift
    for needle in "$@"; do
        [[ $text != *"$needle"* ]] || {
            printf 'expected not to find: %s\nin:\n%s\n' "$needle" "$text"
            return 1
        }
    done
}

# Every fragment on one line. A §31 prefix and the message it is meant to prefix have to be
# asserted together this way: a prefix matched anywhere in $output is matched by any earlier
# line that happens to carry it, which is how a run.bats assertion on a failure path came to be
# true whether or not the failure ever happened.
assertLineContains() {
    local text=$1 line fragment missing
    shift
    while IFS= read -r line; do
        missing=
        for fragment in "$@"; do
            [[ $line == *"$fragment"* ]] || missing=yes
        done
        if [[ -z $missing ]]; then
            return 0
        fi
    done <<<"$text"
    printf 'no single line carries all of: %s\nin:\n%s\n' "$*" "$text"
    return 1
}

assertMatches() {
    local text=$1 regex=$2
    [[ $text =~ $regex ]] || {
        printf 'expected to match: %s\nin:\n%s\n' "$regex" "$text"
        return 1
    }
}

# The token the run is given must never come back out; $output holds stdout and stderr together
# unless a test asks for them apart.
refuteToken() {
    refuteContains "$output" "$FAKE_TOKEN"
}

# §31 holds for every line of $output, including what the bootstrap relays from git, jq and
# the agent CLI. CODEX is the Codex twin of the §31 CLAUDE prefix.
assertPrefixedLines() {
    local line
    [[ -n $output ]] || return 0
    while IFS= read -r line; do
        [[ $line =~ ^\[(SANDCASTLE|GIT|ENGRAM|CLAUDE|CODEX|TEST|GITHUB)\]\  ]] || {
            echo "unprefixed log line: $line"
            return 1
        }
    done <<<"$output"
}

# Points GITHUB_SERVER_URL at a host that demands credentials, so that git actually calls
# sandcastle-askpass. Sets AUTH_LOG (headers the server saw) and SERVER_PID (for teardown).
startChallengingGitServer() {
    local dir="$1/challenge" portFile
    mkdir -p "$dir"
    portFile="$dir/port"
    AUTH_LOG="$dir/auth.log"

    python3 "$BOOTSTRAP_DIR/test/fixtures/unauthorized-git-server.py" "$portFile" "$AUTH_LOG" &
    SERVER_PID=$!

    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s $portFile ]] && break
        sleep 0.05
    done
    [[ -s $portFile ]] || return 1

    export GITHUB_SERVER_URL="http://127.0.0.1:$(cat "$portFile")"
}

stopChallengingGitServer() {
    [[ -n ${SERVER_PID:-} ]] || return 0
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

# Installs a fake docker binary on PATH that records invocations but does not run containers.
# This prevents smoke.sh tests from invoking the real docker with real credentials (§14 and
# the quota leak in earlier project work). The fake records argv in DOCKER_RECORD, simulating
# docker commands without side effects.
installFakeDocker() {
    local root bin
    root=${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR-}}
    [[ -n $root ]] || return 0
    bin="$root/bin"
    DOCKER_RECORD="$root/docker-record"
    mkdir -p "$bin" "$DOCKER_RECORD"

    cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: record the invocation and exit cleanly without running anything.
printf '%s\n' "$@" >"$DOCKER_RECORD/docker.argv"
# Simulate `docker image inspect` behavior for the "image already exists" path.
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
    exit 0
fi
# Simulate `docker build` or `docker run` with a success exit.
exit 0
EOF
    chmod +x "$bin/docker"
    export DOCKER_RECORD="$DOCKER_RECORD"
    export PATH="$bin:$PATH"
}

# Installs a recording stand-in for kubectl, so no test can reach a cluster -- the one in
# deploy/kubernetes/scripts/create-secrets.sh sends a credential to, least of all.
#
# It records two things apart, because they are what the credential rule is about: everything
# that reached argv (one argument per line, appended across invocations, which is what
# /proc/<pid>/cmdline would have shown) and everything that reached stdin. It also keeps a
# one-Secret-per-name store, so a second run of a script sees the first run's result and the
# key names and values can be read back the way `kubectl get` reads them.
#
# The store is written by `apply` out of what it was piped, never by `create --dry-run`: a fake
# that recorded the intent instead of the delivery would be satisfied by a script that rendered
# a Secret and applied nothing.
#
# deploy/kubernetes/scripts/launch-run.sh asks it about Jobs, Pods, events and logs as well, and
# those answers are not invented here: a test writes them into $KUBECTL_RECORD/state, and what
# launch.bats writes there is output recorded from a real k3s cluster, one failure mode at a
# time. The fake decides *which* answer a query wants from the shape of the jsonpath, so it
# stays a stand-in for kubectl rather than a second implementation of the launcher.
installFakeKubectl() {
    local root bin
    root=${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR-}}
    [[ -n $root ]] || return 0
    bin="$root/bin"
    KUBECTL_RECORD="$root/kubectl-record"
    mkdir -p "$bin" "$KUBECTL_RECORD/store" "$KUBECTL_RECORD/state"

    cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Recording stand-in for kubectl. Reaches no cluster; understands only what the Secret scripts
# ask of it, and fails loudly on anything else rather than pretending to have done it.
set -euo pipefail

record=$KUBECTL_RECORD
store="$record/store"
state="$record/state"

printf '%s\n' "$@" >>"$record/argv"
printf '%s\n' "$*" >>"$record/commands"

# Whatever the test put there, or nothing at all, which is what an absent field looks like.
canned() {
    cat "$state/$1" 2>/dev/null || true
}

# The flags the scripts pass, pulled out wherever they sit, so the fake does not depend on
# their order. Everything else is left in "$@" for the verb match below.
namespace=
fromFile=
fromLiteral=
outputFormat=
verb=()
while [ $# -gt 0 ]; do
    case $1 in
        --namespace) namespace=$2; shift 2 ;;
        --from-file=*) fromFile=${1#--from-file=}; shift ;;
        # Supported, and faithfully: the fake must not be the thing that refuses a credential
        # in argv, or the assertion that refuses it could never be seen to fail.
        --from-literal=*) fromLiteral=${1#--from-literal=}; shift ;;
        -o) outputFormat=$2; shift 2 ;;
        -o*) outputFormat=${1#-o}; shift ;;
        --dry-run=*) shift ;;
        -l) shift 2 ;;
        --field-selector) shift 2 ;;
        --container) shift 2 ;;
        -f) shift 2 ;;
        *) verb+=("$1"); shift ;;
    esac
    # `logs -f <pod>` is a follow flag and a pod name, not a filename: once the verb is known to
    # be `logs`, nothing after it may be read as one of the flags above.
    if [ "${verb[0]-}" = logs ]; then break; fi
done

fail() {
    printf 'fake kubectl: %s\n' "$*" >&2
    exit 1
}

case "${verb[*]-}" in
    "get namespace $KUBECTL_FAKE_NAMESPACE")
        [ "${KUBECTL_FAKE_NAMESPACE_MISSING:-no}" = no ] ||
            fail "Error from server (NotFound): namespaces \"$KUBECTL_FAKE_NAMESPACE\" not found"
        printf 'namespace/%s\n' "$KUBECTL_FAKE_NAMESPACE"
        ;;

    "create secret generic "*)
        # Renders the Secret the caller asked for, reading the value out of the file named by
        # --from-file, exactly as the real one does. The value is recorded under the key it
        # will be stored as, so a test can assert what was handed over as well as how.
        name=${verb[3]}
        [ "$outputFormat" = yaml ] || fail "expected -o yaml, got '${outputFormat:-none}'"
        if [ -n "$fromFile" ]; then
            key=${fromFile%%=*}
            path=${fromFile#*=}
            [ -f "$path" ] || fail "--from-file names no readable file"
            cp "$path" "$record/from-file.$key"
            printf '%s\n' "$path" >>"$record/from-file.paths"
        elif [ -n "$fromLiteral" ]; then
            key=${fromLiteral%%=*}
            path="$record/from-literal.$key"
            printf '%s' "${fromLiteral#*=}" >"$path"
        else
            fail "no --from-file and no --from-literal"
        fi
        printf 'apiVersion: v1\nkind: Secret\ntype: Opaque\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n  %s: %s\n' \
            "$name" "$namespace" "$key" "$(base64 <"$path" | tr -d '\n')"
        ;;

    apply)
        manifest=$(cat)
        printf '%s\n' "$manifest" >>"$record/stdin"
        name=$(printf '%s\n' "$manifest" | sed -n 's/^  name: //p' | tr -d '"')
        [ -n "$name" ] || fail "applied manifest has no metadata.name"

        # A Job is not a Secret and has no `data:`; it goes in the record and nowhere else.
        # An applied Job is also what makes `get job <name>` start answering, so a launcher
        # that checked for a name collision *after* applying would see its own Job.
        case $manifest in
            *"kind: Job"*)
                printf '%s\n' "$name" >"$state/applied-job"
                # PSA admits the Job and refuses the Pod, so the refusal arrives as a warning
                # on stderr beside a successful create. The test supplies the text.
                [ ! -f "$state/applyWarning" ] || cat "$state/applyWarning" >&2
                printf 'job.batch/%s created\n' "$name"
                exit 0
                ;;
        esac
        # One file per key, so a second apply of the same Secret replaces rather than adds --
        # and so a test can count what a script left behind. Only the entries under `data:`
        # are read: a key/value shape elsewhere in the manifest is metadata, not a secret.
        rm -rf "${store:?}/$name"
        mkdir -p "$store/$name"
        printf '%s\n' "$manifest" |
            awk '/^data:/ { inData = 1; next }
                 /^[^[:space:]]/ { inData = 0 }
                 inData && NF == 2 { key = $1; sub(/:$/, "", key); print key, $2 }' |
            while read -r key value; do
                printf '%s' "$value" | base64 -d >"$store/$name/$key"
            done
        printf 'secret/%s configured\n' "$name"
        ;;

    "get secret "*)
        name=${verb[2]}
        [ -d "$store/$name" ] ||
            fail "Error from server (NotFound): secrets \"$name\" not found"
        case $outputFormat in
            # The two shapes create-secrets.sh asks for: the key names, and one decoded value
            # piped somewhere that counts it. Neither prints a value the caller did not ask
            # for, which is the property being tested, so the fake does not invent a third.
            go-template=*"range"*)
                for key in "$store/$name"/*; do
                    printf '%s ' "$(basename "$key")"
                done
                ;;
            go-template=*base64decode*)
                key=$(printf '%s' "$outputFormat" | sed -n 's/.*index \.data "\([^"]*\)".*/\1/p')
                [ -f "$store/$name/$key" ] || fail "no key '$key' in secret $name"
                cat "$store/$name/$key"
                ;;
            *) fail "unsupported output format '${outputFormat:-none}'" ;;
        esac
        ;;

    "get serviceaccount "*)
        [ "${KUBECTL_FAKE_SERVICEACCOUNT_MISSING:-no}" = no ] ||
            fail "Error from server (NotFound): serviceaccounts \"${verb[2]}\" not found"
        printf 'serviceaccount/%s\n' "${verb[2]}"
        ;;

    "get job "*)
        # Two questions wear the same verb: "does this Job already exist" (the launcher's
        # collision check, before anything is applied) and "how did it end" (its conditions).
        case $outputFormat in
            jsonpath=*conditions*) canned jobConditions ;;
            *)
                [ -f "$state/job-exists" ] || [ -f "$state/applied-job" ] ||
                    fail "Error from server (NotFound): jobs.batch \"${verb[2]}\" not found"
                printf 'job.batch/%s\n' "${verb[2]}"
                ;;
        esac
        ;;

    "get pod" | "get pod "*)
        # Which answer a query wants is decided by the shape of the jsonpath, so the launcher
        # can change what it asks for without this fake having to agree field by field.
        case $outputFormat in
            *metadata.name*) canned podName ;;
            *PodScheduled*) canned schedulingFacts ;;
            *) canned podFacts ;;
        esac
        ;;

    "get events") canned jobCreateFailure ;;

    logs*) canned logs ;;

    *) fail "unsupported invocation: ${verb[*]-}" ;;
esac
EOF
    chmod +x "$bin/kubectl"

    export KUBECTL_RECORD="$KUBECTL_RECORD"
    export KUBECTL_FAKE_NAMESPACE=sandcastle-agents
    export KUBECTL_FAKE_NAMESPACE_MISSING=no
    export KUBECTL_FAKE_SERVICEACCOUNT_MISSING=no
    export PATH="$bin:$PATH"
}

# Runs as every test file loads this one, before its setup_file, its setup and any test body,
# so the agent CLIs a run can reach are the stand-ins and not the real thing (§13).
# Also install fake docker to prevent smoke.sh tests from running real containers (§14), and
# fake kubectl so no test can reach a cluster with a credential (§14, §15).
installFakeAgentClis
installFakeDocker
installFakeKubectl
