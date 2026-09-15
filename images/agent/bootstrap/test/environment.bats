#!/usr/bin/env bats
# validateEnvironment: fail fast, name the variable, never print a value (§14).

bats_require_minimum_version 1.5.0

load helpers

setup() {
    exportRunEnvironment "$BATS_TEST_TMPDIR"
}

@test "each required variable is named when it is the one missing" {
    local var
    for var in SANDCASTLE_RUN_ID GITHUB_REPOSITORY GITHUB_ISSUE_NUMBER AGENT GITHUB_TOKEN; do
        run env -u "$var" "$SANDCASTLE_RUN"
        [ "$status" -eq 1 ]
        assertContains "$output" "Missing required environment variable(s): $var"
    done
}

@test "an empty variable counts as missing" {
    AGENT='' runBootstrap
    [ "$status" -eq 1 ]
    assertContains "$output" "Missing required environment variable(s): AGENT"
}

@test "every missing variable is reported in one message" {
    run env -u AGENT -u GITHUB_TOKEN "$SANDCASTLE_RUN"
    [ "$status" -eq 1 ]
    assertContains "$output" "Missing required environment variable(s): AGENT GITHUB_TOKEN"
}

@test "the failure message is logged with the SANDCASTLE prefix on stderr" {
    run --separate-stderr env -u AGENT "$SANDCASTLE_RUN"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = '[SANDCASTLE] Missing required environment variable(s): AGENT' ]
}

@test "the run id must be usable as a branch name" {
    SANDCASTLE_RUN_ID='../evil' runBootstrap
    [ "$status" -eq 1 ]
    assertContains "$output" "SANDCASTLE_RUN_ID must start with"
}

@test "the repository must be owner/repo" {
    GITHUB_REPOSITORY='octo/demo/extra' runBootstrap
    [ "$status" -eq 1 ]
    assertContains "$output" "GITHUB_REPOSITORY must be in owner/repo form"
}

@test "the issue number must be a positive integer" {
    GITHUB_ISSUE_NUMBER='7; rm -rf /' runBootstrap
    [ "$status" -eq 1 ]
    assertContains "$output" "GITHUB_ISSUE_NUMBER must be a positive integer"
}

@test "the agent must be one this image can run" {
    AGENT=gemini runBootstrap
    [ "$status" -eq 1 ]
    assertContains "$output" "AGENT must be 'claude' or 'codex'"
}
