#!/usr/bin/env bats
# §14: no credential value reaches the logs or the disk, on any path.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    makeFixtures "$BATS_TEST_TMPDIR"
    exportRunEnvironment "$BATS_TEST_TMPDIR"
}

# $output holds stdout and stderr together unless a test asks for them apart.
refuteToken() {
    [[ $output != *"$FAKE_TOKEN"* ]] || {
        echo "token leaked into output: $output"
        return 1
    }
}

@test "the token never reaches the logs of a successful run" {
    runBootstrap
    [ "$status" -eq 0 ]
    refuteToken
}

@test "the token never reaches the logs when the clone fails" {
    GITHUB_SERVER_URL="file://$BATS_TEST_TMPDIR/absent" runBootstrap
    [ "$status" -eq 1 ]
    refuteToken
}

@test "the token never reaches the logs when the issue fetch fails" {
    GITHUB_ISSUE_NUMBER=404 runBootstrap
    [ "$status" -eq 1 ]
    refuteToken
}

@test "the token never reaches the logs when validation fails" {
    run env -u AGENT "$SANDCASTLE_RUN"
    [ "$status" -eq 1 ]
    refuteToken
}

@test "the token never reaches the logs when the shell is asked to trace" {
    run env SHELLOPTS=xtrace "$SANDCASTLE_RUN"
    [ "$status" -eq 0 ]
    refuteToken
}

@test "the token is not embedded in the remote url or written into the checkout" {
    runBootstrap
    [ "$status" -eq 0 ]

    local repo="$SANDCASTLE_WORKSPACE/repo"
    run grep -r --binary-files=text "$FAKE_TOKEN" "$SANDCASTLE_WORKSPACE"
    [ "$status" -ne 0 ]

    run git -C "$repo" remote get-url origin
    refuteToken
}
