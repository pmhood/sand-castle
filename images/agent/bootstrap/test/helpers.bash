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
