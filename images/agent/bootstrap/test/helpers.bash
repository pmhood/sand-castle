# Shared setup for the sandcastle-run test suite.

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDCASTLE_RUN="$BOOTSTRAP_DIR/sandcastle-run"

# A token value that must never reach stdout, stderr or the checkout (§14).
readonly FAKE_TOKEN='fake-token-3f8b21c7'

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

# §31 holds for every line of $output, including what the bootstrap relays from git and jq.
assertPrefixedLines() {
    local line
    [[ -n $output ]] || return 0
    while IFS= read -r line; do
        [[ $line =~ ^\[(SANDCASTLE|GIT|ENGRAM|CLAUDE|TEST|GITHUB)\]\  ]] || {
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
