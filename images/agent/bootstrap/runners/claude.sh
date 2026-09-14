# shellcheck shell=bash
# Claude Code CLI invocation (docs/ARCHITECTURE.md §27).
#
# Sourced by sandcastle-run once AGENT has selected it. The only thing that lives here is how
# a single non-interactive `claude` process is started; the prompt (§26), the working
# directory and the exit code are the bootstrap's, and identical for both agents.
#
# Authentication (§13, §52): the CLI talks to Anthropic itself using whatever credential it
# finds in the environment it inherits -- CLAUDE_CODE_OAUTH_TOKEN for a subscription OAuth
# token, ANTHROPIC_API_KEY for an API key, or ~/.claude/.credentials.json from a prior
# `claude auth login`. Nothing here reads, copies, logs or forwards that value: injecting it
# is the caller's job (§16) and using it is the CLI's.

invokeAgent() {
    local prompt=$1 status=0

    log CLAUDE "Starting Claude Code CLI in $PWD"
    # --print is the non-interactive mode, and it takes the prompt on stdin, which keeps the
    # issue text out of the process table and out of argv's length limit.
    #
    # The container is the sandbox (§11, §50) and there is no human in it to approve a tool
    # call, so permission prompts are bypassed inside it. pipefail (set by sandcastle-run)
    # makes the pipeline report the CLI's status rather than the logger's.
    claude --print --permission-mode bypassPermissions 2>&1 <<<"$prompt" |
        logStream CLAUDE || status=$?

    log CLAUDE "Claude Code CLI exited with status $status"
    return "$status"
}
