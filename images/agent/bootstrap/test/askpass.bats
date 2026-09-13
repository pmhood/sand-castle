#!/usr/bin/env bats
# sandcastle-askpass: the file whose whole job is handing git a credential.

bats_require_minimum_version 1.5.0

load helpers

ASKPASS="$BOOTSTRAP_DIR/sandcastle-askpass"

setup() {
    makeFixtures "$BATS_TEST_TMPDIR"
    exportRunEnvironment "$BATS_TEST_TMPDIR"
}

teardown() {
    stopChallengingGitServer
}

@test "a username prompt is answered with the token user, not the token" {
    run "$ASKPASS" "Username for 'https://github.com': "
    [ "$status" -eq 0 ]
    [ "$output" = 'x-access-token' ]
}

@test "a password prompt is answered with the token" {
    run "$ASKPASS" "Password for 'https://x-access-token@github.com': "
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_TOKEN" ]
}

@test "an unset token answers empty rather than failing" {
    run env -u GITHUB_TOKEN "$ASKPASS" "Password for 'https://github.com': "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tracing the helper prints no trace of the token" {
    # The two lines before `set +x` takes hold are traced; none of them may hold the token.
    run --separate-stderr env SHELLOPTS=xtrace "$ASKPASS" "Password for 'https://github.com': "
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_TOKEN" ]
    [[ $stderr != *"$FAKE_TOKEN"* ]]
}

@test "git answers a credential challenge with the helper" {
    startChallengingGitServer "$BATS_TEST_TMPDIR"

    runBootstrap
    [ "$status" -eq 1 ]
    [[ $output == *'Clone of octo/demo failed'* ]]

    # The server saw Basic x-access-token:<token>, so the helper is what answered.
    local expected
    expected=$(printf '%s' "x-access-token:$FAKE_TOKEN" | base64)
    [[ $(cat "$AUTH_LOG") == *"Basic $expected"* ]]
}

@test "a challenged clone leaks no token and stays prefixed" {
    startChallengingGitServer "$BATS_TEST_TMPDIR"

    runBootstrap
    [ "$status" -eq 1 ]
    [[ $output != *"$FAKE_TOKEN"* ]]
    assertPrefixedLines
}

@test "git tracing cannot dump the credential git sent" {
    startChallengingGitServer "$BATS_TEST_TMPDIR"

    run env GIT_TRACE_CURL=1 GIT_TRACE_REDACT=0 "$SANDCASTLE_RUN"
    [ "$status" -eq 1 ]
    [[ $output != *"$FAKE_TOKEN"* ]]
    assertPrefixedLines
}
