#!/usr/bin/env bats
# Phase 1 smoke harness tests (docs/ARCHITECTURE.md §35).
# Test that the smoke.sh script correctly validates credentials, builds the image, and runs
# the container without leaking credentials.

bats_require_minimum_version 1.5.0

load helpers

# Locate the smoke script.
SMOKE_SCRIPT="$(cd "$(dirname "$BOOTSTRAP_DIR")" && pwd)/scripts/smoke.sh"

setup() {
    # The smoke script needs docker and a working repository to test against. For now, we
    # test the credential validation logic without actually building/running the image.
    # That is covered by the manual run documented in README.md.
    #
    # The operator's real images/.env.local must never be reachable from an ordinary test: it
    # may hold real credentials, and a test that read them would hand them to the recording
    # docker and write them into a temporary file (#16, §14). SANDCASTLE_ENV_FILE is the seam
    # smoke.sh reads that path through -- the same one
    # deploy/kubernetes/scripts/create-secrets.sh already reads this exact file through
    # (secrets.bats, launch.bats) -- pointed at a path that does not exist unless a test writes
    # it, so credential-file tests never touch the real one.
    export SANDCASTLE_ENV_FILE="$BATS_TEST_TMPDIR/env.local"
}

writeEnvLocalFile() {
    printf '%s' "$1" >"$SANDCASTLE_ENV_FILE"
}

# The real, fixed path smoke.sh falls back to when SANDCASTLE_ENV_FILE is not set -- used only
# by the canary test below, which must write there deliberately to prove the seam keeps it out
# of reach. Anything already there is a developer's real file (or one a prior run left behind by
# mistake) and must never be destroyed, so this backs it up and restores it in teardown.
REAL_ENV_LOCAL_FILE="$(cd "$(dirname "$SMOKE_SCRIPT")/../.." && pwd)/.env.local"

writeRealEnvLocalFile() {
    if [ -f "$REAL_ENV_LOCAL_FILE" ]; then
        REAL_ENV_LOCAL_BACKUP="$BATS_TEST_TMPDIR/real-env.local.backup"
        mv "$REAL_ENV_LOCAL_FILE" "$REAL_ENV_LOCAL_BACKUP"
    fi
    REAL_ENV_LOCAL_WRITTEN=1
    printf '%s' "$1" >"$REAL_ENV_LOCAL_FILE"
}

teardown() {
    [ -n "${REAL_ENV_LOCAL_WRITTEN:-}" ] || return 0
    if [ -n "${REAL_ENV_LOCAL_BACKUP:-}" ]; then
        mv "$REAL_ENV_LOCAL_BACKUP" "$REAL_ENV_LOCAL_FILE"
    else
        rm -f "$REAL_ENV_LOCAL_FILE"
    fi
    REAL_ENV_LOCAL_WRITTEN=
    REAL_ENV_LOCAL_BACKUP=
}

@test "smoke script requires GITHUB_REPOSITORY" {
    run bash -c "unset GITHUB_REPOSITORY GITHUB_ISSUE_NUMBER AGENT; '$SMOKE_SCRIPT'" 2>&1
    [ "$status" -ne 0 ]
    assertContains "$output" "GITHUB_REPOSITORY not set"
}

@test "smoke script requires GITHUB_ISSUE_NUMBER" {
    run bash -c "export GITHUB_REPOSITORY='owner/repo'; unset GITHUB_ISSUE_NUMBER AGENT; '$SMOKE_SCRIPT'" 2>&1
    [ "$status" -ne 0 ]
    assertContains "$output" "GITHUB_ISSUE_NUMBER not set"
}

@test "smoke script accepts arguments for repository and issue" {
    # All three positional arguments reach the run, and the target line is where they become
    # visible. (This body used to end in `:`, so it asserted nothing at all.)
    run bash -c "
        export CLAUDE_CODE_OAUTH_TOKEN='token' GITHUB_TOKEN='github-token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]
    assertContains "$output" 'Target: owner/repo issue #123 with agent claude'
}

@test "smoke script passes invalid GITHUB_REPOSITORY to the container for validation" {
    # Format validation is deferred to the container (sandcastle-run does it).
    # The harness just passes arguments through.
    run bash -c "export CLAUDE_CODE_OAUTH_TOKEN='token' GITHUB_TOKEN='token'; '$SMOKE_SCRIPT' invalid-no-slash 123 claude 2>&1" || true
    # Script succeeds at the harness level; container will validate format on next phase.
    assertContains "$output" 'Target: invalid-no-slash'
}

@test "smoke script passes invalid GITHUB_ISSUE_NUMBER to the container for validation" {
    # Format validation is deferred to the container (sandcastle-run does it).
    # The harness just passes arguments through.
    run bash -c "export CLAUDE_CODE_OAUTH_TOKEN='token' GITHUB_TOKEN='token'; '$SMOKE_SCRIPT' owner/repo 0 claude 2>&1" || true
    # Script succeeds at the harness level; container will validate format on next phase.
    assertContains "$output" 'Target: owner/repo'
}

@test "smoke script requires agent credentials (claude) and never invokes docker without them" {
    run bash -c "
        unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR GITHUB_TOKEN
        export HOME=\$(mktemp -d)
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    # Property: validation fails with non-zero exit and docker is not invoked.
    [ "$status" -ne 0 ]
    # The message names what is missing. HOME is a fresh directory above, so the agent
    # credential is genuinely absent rather than satisfied by the developer's own prior login
    # in ~/.claude, which is what made this test pass for the wrong reason on a Mac.
    assertContains "$output" 'GITHUB_TOKEN' 'CLAUDE_CODE_OAUTH_TOKEN'
    # CRITICAL: Verify docker was NOT invoked (no argv record created).
    # This assertion enforces that validation runs BEFORE docker is touched.
    [ ! -f "$DOCKER_RECORD/docker.argv" ]
}

@test "smoke script requires agent credentials (codex) and never invokes docker without them" {
    run bash -c "
        unset CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_HOME GITHUB_TOKEN
        export HOME=\$(mktemp -d)
        '$SMOKE_SCRIPT' owner/repo 123 codex 2>&1
    "
    # Property: validation fails with non-zero exit and docker is not invoked.
    [ "$status" -ne 0 ]
    # The message names what is missing; HOME is a fresh directory above, so no prior
    # ~/.codex/auth.json can satisfy the agent credential in its place.
    assertContains "$output" 'GITHUB_TOKEN' 'CODEX_API_KEY'
    # CRITICAL: Verify docker was NOT invoked (no argv record created).
    # This assertion enforces that validation runs BEFORE docker is touched.
    [ ! -f "$DOCKER_RECORD/docker.argv" ]
}

# Each of the three below used to end in `[ "$status" -eq 1 ] || [ "$status" -eq 0 ]`, which a
# piped `grep -q` can only ever satisfy: the test could not fail in any shell, and in fact the
# grep found nothing, because no GITHUB_TOKEN was set and validation died before saying a word
# about the agent credential. HOME is a fresh directory in each, so the variable under test is
# the only thing that can satisfy validation.
@test "smoke script accepts CLAUDE_CODE_OAUTH_TOKEN" {
    run bash -c "
        export HOME=\$(mktemp -d)
        export CLAUDE_CODE_OAUTH_TOKEN='test-token' GITHUB_TOKEN='github-token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]
    assertContains "$output" 'Credentials validated'
}

@test "smoke script accepts ANTHROPIC_API_KEY" {
    run bash -c "
        export HOME=\$(mktemp -d)
        unset CLAUDE_CODE_OAUTH_TOKEN
        export ANTHROPIC_API_KEY='test-key' GITHUB_TOKEN='github-token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]
    assertContains "$output" 'Credentials validated'
}

@test "smoke script accepts CODEX_API_KEY" {
    run bash -c "
        export HOME=\$(mktemp -d)
        export CODEX_API_KEY='test-key' GITHUB_TOKEN='github-token'
        '$SMOKE_SCRIPT' owner/repo 123 codex 2>&1
    "
    [ "$status" -eq 0 ]
    assertContains "$output" 'Credentials validated'
}

@test "smoke script does not leak ANY credential variable into output or docker argv" {
    # Test all 7 credential variables with distinct canary values so no single
    # variable can regress without being noticed. This was the vulnerability:
    # two-variable test could pass while CODEX_ACCESS_TOKEN leaked.
    run bash -c "
        export GITHUB_TOKEN='canary-github-1a2b3c'
        export CLAUDE_CODE_OAUTH_TOKEN='canary-claude-2b3c4d'
        export ANTHROPIC_API_KEY='canary-api-key-3c4d5e'
        export ANTHROPIC_AUTH_TOKEN='canary-auth-token-4d5e6f'
        export CODEX_API_KEY='canary-codex-api-5e6f7g'
        export CODEX_ACCESS_TOKEN='canary-codex-access-6f7g8h'
        export CLAUDE_CONFIG_DIR='canary-claude-config-7g8h9i'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    " || true

    # No credential must appear in output. Test each one distinctly.
    refuteContains "$output" "canary-github-1a2b3c"
    refuteContains "$output" "canary-claude-2b3c4d"
    refuteContains "$output" "canary-api-key-3c4d5e"
    refuteContains "$output" "canary-auth-token-4d5e6f"
    refuteContains "$output" "canary-codex-api-5e6f7g"
    refuteContains "$output" "canary-codex-access-6f7g8h"
    refuteContains "$output" "canary-claude-config-7g8h9i"

    # No credential must appear in docker's argv. Test each one distinctly. The record has to
    # exist: guarded by `if`, these assertions would pass by not running at all on the day
    # docker stopped being reached, which is the regression they exist to catch.
    [ -f "$DOCKER_RECORD/docker.argv" ]
    run cat "$DOCKER_RECORD/docker.argv"
    refuteContains "$output" "canary-github-1a2b3c"
    refuteContains "$output" "canary-claude-2b3c4d"
    refuteContains "$output" "canary-api-key-3c4d5e"
    refuteContains "$output" "canary-auth-token-4d5e6f"
    refuteContains "$output" "canary-codex-api-5e6f7g"
    refuteContains "$output" "canary-codex-access-6f7g8h"
    refuteContains "$output" "canary-claude-config-7g8h9i"
}

# Every variable the agent CLIs read for themselves, in smoke.sh's own order.
AGENT_CREDENTIAL_VARS=(
    CLAUDE_CODE_OAUTH_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_AUTH_TOKEN
    CODEX_API_KEY
    CODEX_ACCESS_TOKEN
    CLAUDE_CONFIG_DIR
    CODEX_HOME
)

# `-e VAR` on a variable the host does not have makes it set-but-empty in the container, and
# the CLIs do not read "" back as "absent": an empty CLAUDE_CONFIG_DIR resolves against the
# working directory, so the CLI writes its config into the checkout the agent is working in.
@test "smoke script passes -e only for the credential variables the host has" {
    run bash -c "
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CODEX_API_KEY CODEX_ACCESS_TOKEN \
              CLAUDE_CONFIG_DIR CODEX_HOME
        export GITHUB_TOKEN='github-token' CLAUDE_CODE_OAUTH_TOKEN='token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]

    # The fake docker records one argument per line, so an exact-line match is exactly the
    # `-e VAR` pass-through form: the name reaches docker and the value does not.
    local var
    for var in "${AGENT_CREDENTIAL_VARS[@]}"; do
        run grep -Fxq "$var" "$DOCKER_RECORD/docker.argv"
        if [ "$var" = CLAUDE_CODE_OAUTH_TOKEN ]; then
            [ "$status" -eq 0 ]   # the one the host has is passed through
        else
            [ "$status" -ne 0 ]   # the six it does not have are not
        fi
    done
}

# The same rule for a variable the host sets to nothing, which is how an unset one arrives
# after any layer that defaults it -- an `export VAR="${VAR-}"`, or a Pod env entry with an
# empty value (§16). An empty value carries no credential and no config path.
@test "smoke script passes no -e for a credential variable set to the empty string" {
    run bash -c "
        export GITHUB_TOKEN='github-token' CLAUDE_CODE_OAUTH_TOKEN='token'
        export CLAUDE_CONFIG_DIR='' CODEX_HOME='' CODEX_ACCESS_TOKEN=''
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]

    local var
    for var in CLAUDE_CONFIG_DIR CODEX_HOME CODEX_ACCESS_TOKEN; do
        run grep -Fxq "$var" "$DOCKER_RECORD/docker.argv"
        [ "$status" -ne 0 ]
    done
}

@test "smoke script generates and uses a unique run ID in docker invocation" {
    # Verify the script generates a smoke-<timestamp>-<random> run ID and passes it to docker.
    run bash -c "
        export CLAUDE_CODE_OAUTH_TOKEN='token'
        export GITHUB_TOKEN='github-token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]

    # The run ID appears in the script's output.
    assertMatches "$output" 'smoke-[0-9]+-[0-9a-f]+'

    # And docker is invoked with it, by name: `-e SANDCASTLE_RUN_ID` is one argument per line
    # in the record, so an exact-line match is the pass-through form.
    [ -f "$DOCKER_RECORD/docker.argv" ]
    run grep -Fxq SANDCASTLE_RUN_ID "$DOCKER_RECORD/docker.argv"
    [ "$status" -eq 0 ]
}

# The three precedence cases #26 asks for, all observed through the fake docker's per-variable
# docker.env.* record (installFakeDocker in helpers.bash) rather than through $output or
# docker.argv: the value itself must never reach either (§14), so the only way to say which
# value won is to read it back from a file no credential-handling code in smoke.sh itself
# writes.

@test "smoke script prefers an exported credential over images/.env.local" {
    writeEnvLocalFile "GITHUB_TOKEN='stale-file-github-a1b2c3'
CLAUDE_CODE_OAUTH_TOKEN='stale-file-claude-d4e5f6'
"
    run bash -c "
        export GITHUB_TOKEN='fresh-exported-github-1a2b3c'
        export CLAUDE_CODE_OAUTH_TOKEN='fresh-exported-claude-4d5e6f'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]

    # Neither value reaches output, whichever won.
    refuteContains "$output" 'stale-file-github-a1b2c3' 'stale-file-claude-d4e5f6' \
        'fresh-exported-github-1a2b3c' 'fresh-exported-claude-4d5e6f'

    run cat "$DOCKER_RECORD/docker.env.GITHUB_TOKEN"
    assertContains "$output" 'fresh-exported-github-1a2b3c'
    refuteContains "$output" 'stale-file-github-a1b2c3'

    run cat "$DOCKER_RECORD/docker.env.CLAUDE_CODE_OAUTH_TOKEN"
    assertContains "$output" 'fresh-exported-claude-4d5e6f'
    refuteContains "$output" 'stale-file-claude-d4e5f6'
}

@test "smoke script uses images/.env.local's value when nothing is exported" {
    writeEnvLocalFile "GITHUB_TOKEN='only-in-file-github-7g8h9i'
CLAUDE_CODE_OAUTH_TOKEN='only-in-file-claude-0j1k2l'
"
    run bash -c "
        unset GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]
    refuteContains "$output" 'only-in-file-github-7g8h9i' 'only-in-file-claude-0j1k2l'

    run cat "$DOCKER_RECORD/docker.env.GITHUB_TOKEN"
    assertContains "$output" 'only-in-file-github-7g8h9i'

    run cat "$DOCKER_RECORD/docker.env.CLAUDE_CODE_OAUTH_TOKEN"
    assertContains "$output" 'only-in-file-claude-0j1k2l'
}

# The case where "environment wins" and "empty is not a value" (§14, #14, validateCredentials)
# could contradict each other: an exported-but-empty GITHUB_TOKEN must be treated as absent, so
# the file's value is used rather than the empty string winning by virtue of being exported.
@test "smoke script treats an exported empty credential as absent and falls back to the file" {
    writeEnvLocalFile "GITHUB_TOKEN='fallback-file-github-3m4n5o'
"
    run bash -c "
        export GITHUB_TOKEN=''
        export CLAUDE_CODE_OAUTH_TOKEN='exported-claude-token'
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "
    [ "$status" -eq 0 ]
    refuteContains "$output" 'fallback-file-github-3m4n5o'

    run cat "$DOCKER_RECORD/docker.env.GITHUB_TOKEN"
    assertContains "$output" 'fallback-file-github-3m4n5o'
}

# #16: an operator's real images/.env.local -- exactly what README.md recommends keeping for
# repeat smoke runs -- must never be reachable from this suite. Before SANDCASTLE_ENV_FILE
# existed, every test without a writeEnvLocalFile call still had smoke.sh source whatever real
# file happened to be sitting there, handing its credentials to the recording docker and
# writing them into a file under BATS_TEST_TMPDIR. setup() now points smoke.sh elsewhere for
# every test in this file; this test proves that seam actually holds, by planting a real file
# with canary credentials at the true default path and confirming none of them turn up
# anywhere.
@test "smoke script never reads the operator's real images/.env.local" {
    writeRealEnvLocalFile "GITHUB_TOKEN='canary-real-github-9k2m4p'
CLAUDE_CODE_OAUTH_TOKEN='canary-real-claude-7h3n1q'
"
    run bash -c "
        unset GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        export HOME=\$(mktemp -d)
        '$SMOKE_SCRIPT' owner/repo 123 claude 2>&1
    "

    # Behaves exactly like "smoke script requires agent credentials (claude) and never invokes
    # docker without them" above, which plants no real file at all: validation fails on the
    # same missing-credential message, before docker is ever touched. That is the run behaving
    # identically whether or not a populated real file exists on disk.
    [ "$status" -ne 0 ]
    assertContains "$output" 'GITHUB_TOKEN' 'CLAUDE_CODE_OAUTH_TOKEN'
    [ ! -f "$DOCKER_RECORD/docker.argv" ]

    refuteContains "$output" 'canary-real-github-9k2m4p' 'canary-real-claude-7h3n1q'

    # Nor did it reach any file this suite creates: the stand-in docker's per-variable record,
    # the fake agent CLIs' record, or anything else under this test's own tmpdir. The real file
    # itself lives outside BATS_TEST_TMPDIR, so this only catches a copy that should not exist.
    run grep -rF 'canary-real' "$BATS_TEST_TMPDIR"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "smoke script is valid bash syntax" {
    bash -n "$SMOKE_SCRIPT"
}
