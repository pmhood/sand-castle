#!/usr/bin/env bats
# Workspace, checkout, issue context and result reporting against local fixtures.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    makeFixtures "$BATS_TEST_TMPDIR"
    exportRunEnvironment "$BATS_TEST_TMPDIR"
}

@test "the run branch is derived from the run id" {
    source "$SANDCASTLE_RUN"

    SANDCASTLE_RUN_ID=run-abc123
    [ "$(runBranch)" = 'sandcastle/run-abc123' ]

    SANDCASTLE_RUN_ID=2024.09.13_run-7
    [ "$(runBranch)" = 'sandcastle/2024.09.13_run-7' ]
}

@test "prepareWorkspace creates the repository directory" {
    source "$SANDCASTLE_RUN"

    prepareWorkspace
    [ -d "$SANDCASTLE_WORKSPACE/repo" ]
}

@test "reportResult exits with the agent's exit code" {
    source "$SANDCASTLE_RUN"

    run reportResult 0
    [ "$status" -eq 0 ]
    [[ $output == *'Run run-abc123 completed'* ]]

    run reportResult 42
    [ "$status" -eq 42 ]
    [[ $output == *'Run run-abc123 failed'* ]]
    [[ $output == *'exit_code=42'* ]]
}

@test "a full run clones the repository onto the run branch and exits 0" {
    runBootstrap
    [ "$status" -eq 0 ]

    local repo="$SANDCASTLE_WORKSPACE/repo"
    [ -f "$repo/README.md" ]
    [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = 'sandcastle/run-abc123' ]
    [ "$(git -C "$repo" config user.name)" = 'Sand Castle agent' ]
    [ "$(git -C "$repo" config user.email)" = 'sandcastle-agent@users.noreply.github.com' ]
    [ -z "$(git -C "$repo" status --porcelain)" ]
}

@test "a full run pushes nothing" {
    runBootstrap
    [ "$status" -eq 0 ]

    run git -C "$BATS_TEST_TMPDIR/octo/demo.git" branch --list 'sandcastle/*'
    [ -z "$output" ]
}

@test "the issue context file holds title, body and labels" {
    runBootstrap
    [ "$status" -eq 0 ]

    local context="$SANDCASTLE_WORKSPACE/issue-context.json"
    [ -f "$context" ]
    [ "$(jq -r '.run_id' "$context")" = 'run-abc123' ]
    [ "$(jq -r '.repository' "$context")" = 'octo/demo' ]
    [ "$(jq -r '.number' "$context")" = '7' ]
    [ "$(jq -r '.title' "$context")" = 'Add authentication middleware' ]
    [ "$(jq -r '.body' "$context")" = 'Sessions must expire after 30 minutes.' ]
    [ "$(jq -r '.labels | join(",")' "$context")" = 'bug,effort:medium' ]
}

@test "the issue context file is written outside the checkout" {
    runBootstrap
    [ "$status" -eq 0 ]
    [ ! -e "$SANDCASTLE_WORKSPACE/repo/issue-context.json" ]
}

@test "a missing issue fails the run with the GITHUB prefix" {
    GITHUB_ISSUE_NUMBER=404 runBootstrap
    [ "$status" -eq 1 ]
    [[ $output == *'[GITHUB]'* ]]
    [[ $output == *'Could not fetch issue #404'* ]]
}

@test "a clone failure fails the run with the GIT prefix" {
    GITHUB_SERVER_URL="file://$BATS_TEST_TMPDIR/absent" runBootstrap
    [ "$status" -eq 1 ]
    [[ $output == *'[GIT]'* ]]
    [[ $output == *'Clone of octo/demo failed'* ]]
}

@test "a payload that is not json fails the run with the GITHUB prefix" {
    GITHUB_ISSUE_NUMBER=8 runBootstrap
    [ "$status" -eq 1 ]
    [[ $output == *'[GITHUB] parse error'* ]]
    [[ $output == *'Could not parse the GitHub issue payload'* ]]
    [ ! -e "$SANDCASTLE_WORKSPACE/issue-context.json" ]
}

@test "every log line carries a section 31 prefix, on success and on every failure" {
    runBootstrap
    [ "$status" -eq 0 ]
    assertPrefixedLines

    GITHUB_SERVER_URL="file://$BATS_TEST_TMPDIR/absent" runBootstrap
    [ "$status" -eq 1 ]
    assertPrefixedLines

    GITHUB_ISSUE_NUMBER=404 runBootstrap
    [ "$status" -eq 1 ]
    assertPrefixedLines

    GITHUB_ISSUE_NUMBER=8 runBootstrap
    [ "$status" -eq 1 ]
    assertPrefixedLines

    run env -u AGENT "$SANDCASTLE_RUN"
    [ "$status" -eq 1 ]
    assertPrefixedLines
}
