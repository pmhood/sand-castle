#!/usr/bin/env bash
# Phase 1 smoke test harness (docs/ARCHITECTURE.md §35).
#
# Proves that Claude CLI works non-interactively inside the container with supplied OAuth
# credentials, checking out a repository and reading an issue. Designed to be run by hand by
# the repo owner with their own credentials; it sources credentials from the environment or
# from a git-ignored local file, never from command-line arguments.
#
# Usage:
#   GITHUB_REPOSITORY=owner/repo GITHUB_ISSUE_NUMBER=123 AGENT=claude \
#     CLAUDE_CODE_OAUTH_TOKEN="..." ./images/agent/scripts/smoke.sh
#
# or:
#   export CLAUDE_CODE_OAUTH_TOKEN="..."
#   ./images/agent/scripts/smoke.sh owner/repo 123 claude

set -euo pipefail
# Tracing expands credential values, so keep it off however this was invoked (§14).
set +x

# shellcheck disable=SC2155 # The command substitution fails fast, so the return value is safe.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly AGENT_DIR="$(dirname "$SCRIPT_DIR")"

readonly IMAGE_DEFAULT="sandcastle-agent:dev"

# Credentials are never logged; only credential variable names are printed.
log() {
    printf '[SMOKE] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# Parse arguments. The environment variables take precedence; arguments are accepted for
# convenience in scripts. Either way, credential values never appear in argv.
parseArgs() {
    local arg_repo=${1-} arg_issue=${2-} arg_agent=${3-}

    GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$arg_repo}"
    GITHUB_ISSUE_NUMBER="${GITHUB_ISSUE_NUMBER:-$arg_issue}"
    AGENT="${AGENT:-$arg_agent}"

    # Repository and issue are required; agent defaults to claude if not set.
    [[ -n "$GITHUB_REPOSITORY" ]] || die "GITHUB_REPOSITORY not set (usage: $0 owner/repo issue-number [agent])"
    [[ -n "$GITHUB_ISSUE_NUMBER" ]] || die "GITHUB_ISSUE_NUMBER not set (usage: $0 owner/repo issue-number [agent])"
    AGENT="${AGENT:-claude}"
}

# A run ID must be unique and must not contain credentials. Generate one now.
generateRunId() {
    local timestamp random
    # Use timestamp + random to ensure uniqueness across reruns in the same second.
    timestamp=$(date +%s)
    # On macOS, nanoseconds are not available in a portable way, so use a random string.
    random=$(python3 -c "import random; print(''.join(random.choices('0123456789abcdef', k=6)))")
    SANDCASTLE_RUN_ID="smoke-${timestamp}-${random}"
}

# Locate the credential file. This file is git-ignored and contains credentials as KEY=VALUE
# pairs, one per line. Only variables that the selected agent needs are read.
locateCredentialFile() {
    local candidate
    candidate="$(dirname "$AGENT_DIR")/.env.local"
    if [[ -f "$candidate" ]]; then
        CREDENTIAL_FILE="$candidate"
    fi
}

# Source a credential file if one exists. Do not export the variables; they will be passed
# to the container through the environment, and the script never logs them (§14).
sourceCredentialFile() {
    [[ -z "${CREDENTIAL_FILE-}" ]] && return 0
    [[ -f "$CREDENTIAL_FILE" ]] || die "Credential file $CREDENTIAL_FILE not found"
    # Use 'set -a' to export, then unset it so these variables don't leak to subshells.
    set -a
    # shellcheck source=/dev/null
    source "$CREDENTIAL_FILE"
    set +a
}

# Validate that the required credentials are present for the selected agent and GitHub.
# Credentials are never logged; only their variable names are validated (§14).
validateCredentials() {
    local status=0 missing=()

    # GitHub token is required to clone and read the issue.
    [[ -n "${GITHUB_TOKEN-}" ]] || missing+=("GITHUB_TOKEN (GitHub API token)")

    case "$AGENT" in
        claude)
            # Claude accepts OAuth token, API key, or prior login.
            if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN-}" ]] && \
               [[ -z "${ANTHROPIC_API_KEY-}" ]] && \
               [[ -z "${ANTHROPIC_AUTH_TOKEN-}" ]] && \
               [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]]; then
                missing+=(
                    "CLAUDE_CODE_OAUTH_TOKEN (OAuth token)"
                    "ANTHROPIC_API_KEY (API key)"
                    "ANTHROPIC_AUTH_TOKEN (API key)"
                    "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json (prior login)"
                )
            fi
            ;;
        codex)
            # Codex accepts API key, access token, or prior login.
            if [[ -z "${CODEX_API_KEY-}" ]] && \
               [[ -z "${CODEX_ACCESS_TOKEN-}" ]] && \
               [[ ! -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]]; then
                missing+=(
                    "CODEX_API_KEY (API key)"
                    "CODEX_ACCESS_TOKEN (access token)"
                    "\${CODEX_HOME:-\$HOME/.codex}/auth.json (prior login)"
                )
            fi
            ;;
        *)
            die "Unknown agent: $AGENT"
            ;;
    esac

    if [[ ${#missing[@]} -gt 0 ]]; then
        local github_msg agent_msg
        # Separate GITHUB_TOKEN requirement from agent-specific requirements
        if [[ " ${missing[*]} " =~ " GITHUB_TOKEN " ]]; then
            github_msg="GITHUB_TOKEN is required. "
            missing=("${missing[@]/GITHUB_TOKEN (GitHub API token)/}")  # Remove GITHUB_TOKEN from array
        fi
        if [[ ${#missing[@]} -gt 0 ]]; then
            agent_msg="For agent '$AGENT', set one of: ${missing[*]}"
        fi
        die "${github_msg}${agent_msg}"
    fi

    log "Credentials validated for agent $AGENT"
}

# Validate that the image can be built and that required tools are available.
checkBuildPrerequisites() {
    command -v docker >/dev/null || die "docker not found on PATH"
    [[ -f "$AGENT_DIR/Dockerfile" ]] || die "Dockerfile not found at $AGENT_DIR/Dockerfile"
    log "Build prerequisites found"
}

# Build the image if it does not exist, or if requested.
buildImage() {
    local image="${1:-$IMAGE_DEFAULT}"
    if docker image inspect "$image" >/dev/null 2>&1; then
        log "Image $image already exists; skipping build (use docker rmi to rebuild)"
        return 0
    fi
    log "Building image $image from $AGENT_DIR/Dockerfile"
    docker build -t "$image" "$AGENT_DIR"
}

# Log the target for operator clarity (format validation happens in the container).
logTarget() {
    log "Target: $GITHUB_REPOSITORY issue #$GITHUB_ISSUE_NUMBER with agent $AGENT"
}

# Run the container. Credentials are passed through the environment, never through argv.
# §14: credential values never appear in the process table or logs.
runContainer() {
    local image="${1:-$IMAGE_DEFAULT}"
    local status=0

    log "Starting container $image"
    log "  Repository: $GITHUB_REPOSITORY"
    log "  Issue: #$GITHUB_ISSUE_NUMBER"
    log "  Agent: $AGENT"
    log "  Run ID: $SANDCASTLE_RUN_ID"
    log ""

    # Pass credentials through the environment to docker run. The credential values never
    # appear in the command line (which the process table would expose), only their variable
    # names. The subshell exits with the container's exit code.
    (
        export GITHUB_TOKEN SANDCASTLE_RUN_ID GITHUB_REPOSITORY GITHUB_ISSUE_NUMBER AGENT
        # Pass through any agent-specific credentials that are set, but never log them.
        export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN-}"
        export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY-}"
        export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN-}"
        export CODEX_API_KEY="${CODEX_API_KEY-}"
        export CODEX_ACCESS_TOKEN="${CODEX_ACCESS_TOKEN-}"
        export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR-}"
        export CODEX_HOME="${CODEX_HOME-}"

        docker run --rm \
            -e SANDCASTLE_RUN_ID \
            -e GITHUB_REPOSITORY \
            -e GITHUB_ISSUE_NUMBER \
            -e AGENT \
            -e GITHUB_TOKEN \
            -e CLAUDE_CODE_OAUTH_TOKEN \
            -e ANTHROPIC_API_KEY \
            -e ANTHROPIC_AUTH_TOKEN \
            -e CODEX_API_KEY \
            -e CODEX_ACCESS_TOKEN \
            -e CLAUDE_CONFIG_DIR \
            -e CODEX_HOME \
            "$image"
    ) || status=$?

    return "$status"
}

reportResult() {
    local status=$1
    if [[ $status -eq 0 ]]; then
        log ""
        log "Phase 1 smoke test PASSED"
        log "  The agent successfully read the repository and issue."
        log "  (Changes to the repository are not pushed; that is a later phase.)"
    else
        log ""
        log "Phase 1 smoke test FAILED with exit code $status"
        log "  Check the container output above for details."
    fi
    return "$status"
}

main() {
    parseArgs "$@"
    generateRunId
    locateCredentialFile
    sourceCredentialFile
    validateCredentials
    logTarget
    checkBuildPrerequisites
    buildImage "$IMAGE_DEFAULT"

    local status=0
    runContainer "$IMAGE_DEFAULT" || status=$?
    reportResult "$status"
}

main "$@"
