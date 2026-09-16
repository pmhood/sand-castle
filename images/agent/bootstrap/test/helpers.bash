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

# Runs as every test file loads this one, before its setup_file, its setup and any test body,
# so the agent CLIs a run can reach are the stand-ins and not the real thing (§13).
# Also install fake docker to prevent smoke.sh tests from running real containers (§14).
installFakeAgentClis
installFakeDocker
