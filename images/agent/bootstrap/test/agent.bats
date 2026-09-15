#!/usr/bin/env bats
# runAgent: dispatch on AGENT (§27), the prompt each runner sends (§26), and the credential
# the CLI is handed (§13). Fake agent CLIs on PATH, so no credential and no network.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    makeFixtures "$BATS_TEST_TMPDIR"
    exportRunEnvironment "$BATS_TEST_TMPDIR"
}

@test "AGENT selects the runner, and the CLI it did not select never starts" {
    runBootstrap
    [ "$status" -eq 0 ]
    [ -f "$AGENT_CLI_RECORD/claude.prompt" ]
    [ ! -e "$AGENT_CLI_RECORD/codex.prompt" ]

    resetWorkspace
    AGENT=codex runBootstrap
    [ "$status" -eq 0 ]
    [ -f "$AGENT_CLI_RECORD/codex.prompt" ]
}

@test "an AGENT with no runner fails instead of defaulting to Claude" {
    source "$SANDCASTLE_RUN"

    AGENT=gemini
    run runAgent
    [ "$status" -eq 1 ]
    assertContains "$output" "No runner for AGENT 'gemini'"
    [ ! -e "$AGENT_CLI_RECORD/claude.prompt" ]
}

@test "a runner that cannot be read fails through the prefixed log" {
    source "$SANDCASTLE_RUN"

    RUNNERS_DIR="$BATS_TEST_TMPDIR/absent"
    run runAgent
    [ "$status" -eq 1 ]
    assertContains "$output" '[SANDCASTLE] Could not load the claude runner'
}

@test "a runner that is not valid bash reports what bash objected to" {
    source "$SANDCASTLE_RUN"

    RUNNERS_DIR="$BATS_TEST_TMPDIR/broken"
    mkdir -p "$RUNNERS_DIR"
    printf 'invokeAgent() {\n' >"$RUNNERS_DIR/claude.sh"

    run runAgent
    [ "$status" -eq 1 ]
    # bash's own complaint is relayed through the prefixed log, not swallowed.
    assertLineContains "$output" '[SANDCASTLE]' 'syntax error'
    assertLineContains "$output" '[SANDCASTLE] The claude runner at' 'is not valid bash'
}

@test "each CLI is invoked non-interactively, with the prompt out of its arguments" {
    runBootstrap
    [ "$status" -eq 0 ]
    run cat "$AGENT_CLI_RECORD/claude.argv"
    assertContains "$output" '--print'
    assertContains "$output" '--permission-mode'
    refuteContains "$output" 'Sessions must expire'

    resetWorkspace
    AGENT=codex runBootstrap
    [ "$status" -eq 0 ]
    run cat "$AGENT_CLI_RECORD/codex.argv"
    assertContains "$output" 'exec'
    refuteContains "$output" 'Sessions must expire'
}

@test "the prompt carries the run, repository, issue and requirements of section 26" {
    runBootstrap
    [ "$status" -eq 0 ]

    run cat "$AGENT_CLI_RECORD/claude.prompt"
    assertContains "$output" 'Sand Castle agent sandbox'
    assertContains "$output" 'run-abc123'
    assertContains "$output" 'octo/demo'
    assertContains "$output" '#7 Add authentication middleware'
    assertContains "$output" 'Sessions must expire after 30 minutes.'
    assertContains "$output" 'bug, effort:medium'
    assertContains "$output" '- inspect the repository before changing code'
    assertContains "$output" '- run relevant tests'
}

@test "both runners send the same prompt" {
    runBootstrap
    [ "$status" -eq 0 ]

    resetWorkspace
    AGENT=codex runBootstrap
    [ "$status" -eq 0 ]

    run diff "$AGENT_CLI_RECORD/claude.prompt" "$AGENT_CLI_RECORD/codex.prompt"
    [ "$status" -eq 0 ]
}

@test "the agent runs inside the checkout, not in the workspace root" {
    runBootstrap
    [ "$status" -eq 0 ]
    [ "$(cat "$AGENT_CLI_RECORD/claude.cwd")" = "$SANDCASTLE_WORKSPACE/repo" ]
}

@test "the agent's output is streamed under its own section 31 prefix" {
    runBootstrap
    [ "$status" -eq 0 ]
    assertContains "$output" '[CLAUDE] fake claude read the prompt'
    assertContains "$output" '[CLAUDE] fake claude wrote to stderr'
    assertPrefixedLines

    resetWorkspace
    AGENT=codex runBootstrap
    [ "$status" -eq 0 ]
    assertContains "$output" '[CODEX] fake codex read the prompt'
    assertContains "$output" '[CODEX] fake codex wrote to stderr'
    assertPrefixedLines
}

@test "the CLI's exit code is the run's exit code, unchanged" {
    AGENT_CLI_EXIT=42 runBootstrap
    [ "$status" -eq 42 ]
    assertContains "$output" '[CLAUDE] Claude Code CLI exited with status 42'
    assertContains "$output" 'Run run-abc123 failed'
    assertContains "$output" 'exit_code=42'

    resetWorkspace
    AGENT=codex AGENT_CLI_EXIT=7 runBootstrap
    [ "$status" -eq 7 ]
    assertContains "$output" '[CODEX] Codex CLI exited with status 7'
}

@test "the agent's credential reaches its CLI and reaches nothing else" {
    export CLAUDE_CODE_OAUTH_TOKEN=$FAKE_AGENT_CREDENTIAL
    export CODEX_API_KEY=$FAKE_AGENT_CREDENTIAL

    local agent
    for agent in claude codex; do
        resetWorkspace
        AGENT=$agent runBootstrap
        [ "$status" -eq 0 ]

        # Handing the credential to the CLI is the runner's whole job (§13, §52) ...
        [ "$(cat "$AGENT_CLI_RECORD/$agent.credential")" = "$FAKE_AGENT_CREDENTIAL" ]
        # ... and it must get there without passing through the log, the arguments the
        # process table exposes, or the prompt.
        refuteContains "$output" "$FAKE_AGENT_CREDENTIAL"
        run grep -r --binary-files=text "$FAKE_AGENT_CREDENTIAL" \
            "$AGENT_CLI_RECORD/$agent.argv" "$AGENT_CLI_RECORD/$agent.prompt" \
            "$SANDCASTLE_WORKSPACE"
        [ "$status" -ne 0 ]
    done
}
