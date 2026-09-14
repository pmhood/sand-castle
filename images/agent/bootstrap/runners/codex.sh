# shellcheck shell=bash
# Codex CLI invocation (docs/ARCHITECTURE.md §27).
#
# The twin of runners/claude.sh: same contract, different CLI. Keeping the two invocations
# apart here is the whole point of the adapter -- the CLIs disagree about flags and about
# where credentials come from, and that disagreement stops at this directory.
#
# Authentication (§13, §52): the CLI talks to OpenAI itself using whatever credential it finds
# -- CODEX_API_KEY for an API key, CODEX_ACCESS_TOKEN for a ChatGPT access token, or
# $CODEX_HOME/auth.json (default ~/.codex/auth.json) written by `codex login`. Note that
# OPENAI_API_KEY alone does not authenticate this version. Nothing here reads, copies, logs or
# forwards that value: injecting it is the caller's job (§16) and using it is the CLI's.

invokeAgent() {
    local prompt=$1 status=0

    log CODEX "Starting Codex CLI in $PWD"
    # `codex exec` is the non-interactive mode and `-` makes it read the prompt from stdin,
    # which keeps the issue text out of the process table and out of argv's length limit.
    #
    # Codex sandboxes the commands it runs; inside this container it is already externally
    # sandboxed (§11, §50), and the bypass flag is what it asks for in that situation. Colour
    # is forced off so no ANSI escape reaches the run log. pipefail (set by sandcastle-run)
    # makes the pipeline report the CLI's status rather than the logger's.
    codex exec --dangerously-bypass-approvals-and-sandbox --color never - 2>&1 <<<"$prompt" |
        logStream CODEX || status=$?

    log CODEX "Codex CLI exited with status $status"
    return "$status"
}
