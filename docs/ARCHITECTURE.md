# Sand Castle
## Architecture Build Document

**Product:** Sand Castle  
**Purpose:** Kubernetes-based execution environment for GitHub-triggered coding agents  
**Initial agents:** Claude Code CLI and Codex CLI  
**Primary persistence/context service:** Engram  
**Primary runtime:** Kubernetes  
**Authentication model:** OAuth credentials injected into agent containers; agents use their native CLI authentication, not provider APIs directly.

---

# 1. Architecture Goal

Sand Castle exists to prove the following architecture:

```text
GitHub Issue
     │
     │ label added
     ▼
Sand Castle
     │
     │ trigger rule
     ▼
Create Agent Run
     │
     ▼
Create Sandbox
     │
     ▼
Kubernetes Pod
     │
     ├── repository checkout
     ├── Engram connection
     ├── OAuth credentials
     └── Claude / Codex CLI
              │
              ▼
        Agent performs work
              │
              ▼
        Commit / Result
              │
              ▼
           GitHub
```

The first milestone should answer one question:

> Can a GitHub Issue label reliably launch an isolated Kubernetes workload that authenticates using a Claude CLI OAuth token, reads the issue, modifies the repository, and reports its result?

Everything else is secondary until this succeeds reliably.

---

# 2. Architectural Principles

## 2.1 Build the narrowest complete vertical slice

Do not begin by building:

- a general workflow engine
- a custom Kubernetes operator
- multiple agent coordination
- elaborate queue infrastructure
- multi-cluster support
- a plugin framework
- a complete web UI
- sophisticated sandbox persistence
- complex CRDs

The first implementation should have the smallest number of moving pieces capable of proving the system.

---

## 2.2 A Run is the domain object

Sand Castle should think in terms of:

```text
Run
```

rather than:

```text
Pod
```

A Pod is only the Kubernetes execution mechanism for a Run.

Conceptually:

```text
Run
├── Trigger
├── Repository
├── Issue
├── Sandbox
├── Runtime
│    └── Kubernetes Pod
├── Agent
├── Logs
└── Result
```

This separation will make it easier to change execution infrastructure later.

---

## 2.3 Kubernetes should remain replaceable

The application layer should not tightly couple agent orchestration logic to Kubernetes APIs.

Prefer:

```text
RunService
    │
    ▼
SandboxRuntime
    │
    └── KubernetesRuntime
```

rather than allowing controllers and API handlers to directly create Pods.

---

# 3. Vertical Slice Definition

The initial slice should support exactly one workflow.

## Trigger

A label is added to a GitHub Issue:

```text
agent:run
```

For the first implementation, the configured repository has one default agent:

```text
Claude Code CLI
```

---

## Expected flow

```text
1. GitHub emits issue labeled webhook

2. Sand Castle receives webhook

3. Sand Castle validates webhook signature

4. Sand Castle verifies:
   - event is issues
   - action is labeled
   - label is agent:run
   - repository is configured

5. Sand Castle creates Run record

6. Sand Castle launches Kubernetes Pod

7. Pod receives:
   - repository URL
   - issue number
   - GitHub token
   - Claude OAuth credentials
   - Engram configuration
   - Sand Castle Run ID

8. Container checks out repository

9. Container initializes Engram

10. Container launches Claude Code CLI

11. Claude reads the issue

12. Claude changes repository files

13. Claude runs tests

14. Runtime captures result

15. Container optionally commits/pushes changes

16. Sand Castle updates Run

17. Sand Castle comments result on GitHub Issue

18. Pod exits

19. Kubernetes Pod is eventually cleaned up
```

Engram configuration and initialization (steps 7 and 9) are not implemented yet; §41 covers when they are added.

Success means this sequence works repeatedly.

---

# 4. Initial System Components

The vertical slice needs only four primary components.

```text
                     ┌──────────────────┐
                     │      GitHub      │
                     └────────┬─────────┘
                              │ webhook
                              ▼
                   ┌──────────────────────┐
                   │ Sand Castle Server   │
                   │                      │
                   │ API                  │
                   │ Trigger Processor    │
                   │ Run Manager          │
                   │ Kubernetes Runtime   │
                   └──────────┬───────────┘
                              │
                         Kubernetes API
                              │
                              ▼
                ┌─────────────────────────┐
                │ Agent Sandbox Pod       │
                │                         │
                │ bootstrap               │
                │ git                     │
                │ Engram client           │
                │ Claude Code CLI         │
                │ Codex CLI               │
                └─────────────────────────┘
```

Supporting infrastructure:

```text
Postgres
Kubernetes Secrets
GitHub Webhooks
Engram
```

Engram is not part of the running system yet; §41 covers when it is added.

---

# 5. Sand Castle Server

For the first version, build Sand Castle as a single deployable backend service.

Avoid microservices.

Suggested internal modules:

```text
sandcastle-server

├── github
│   ├── webhook-handler
│   ├── signature-validator
│   └── github-client
│
├── triggers
│   ├── trigger-evaluator
│   └── repository-config
│
├── runs
│   ├── run-service
│   ├── run-repository
│   └── run-state-machine
│
├── sandbox
│   ├── sandbox-service
│   └── runtime-interface
│
├── kubernetes
│   ├── kubernetes-runtime
│   ├── pod-builder
│   └── pod-watcher
│
└── api
    ├── runs
    ├── repositories
    └── health
```

---

# 6. Technology Recommendation

A pragmatic implementation could use:

```text
TypeScript
Node.js
Fastify or NestJS
PostgreSQL
Kubernetes JavaScript client
React / Next.js frontend
```

NestJS is attractive if Sand Castle is expected to grow substantially because its module boundaries map well to:

- Runs
- GitHub
- Kubernetes
- Agents
- Sandboxes
- Engram

Fastify would be equally reasonable for the proof-of-concept if simplicity is preferred.

The architecture matters more than the framework.

---

# 7. Persistence

Use PostgreSQL from the beginning.

Do not use Kubernetes resources themselves as the primary Sand Castle database.

Initial tables can remain small.

## repositories

```text
id
github_owner
github_repo
default_agent
enabled
created_at
updated_at
```

---

## trigger_rules

```text
id
repository_id
event_type
label
agent
enabled
created_at
updated_at
```

For the first slice:

```text
event_type = issue_label_added
label = agent:run
agent = claude
```

---

## runs

```text
id
repository_id
github_issue_number
github_issue_title
github_event_id

agent

state
stage

sandbox_id
pod_name
namespace

started_at
completed_at
created_at
updated_at

exit_code
result_summary
error_message
```

Initially, avoid over-normalizing.

---

# 8. Run State Machine

Create explicit application-level states.

Example:

```text
queued
preparing
sandbox_creating
starting
running
completing
completed
failed
cancelled
timed_out
```

Also track stage separately:

```text
github
trigger
sandbox
kubernetes
agent
result
```

Example:

```json
{
  "state": "running",
  "stage": "agent"
}
```

This maps directly to the UI pipeline.

---

# 9. GitHub Integration

## Webhook endpoint

Initial endpoint:

```text
POST /api/github/webhook
```

Verify the GitHub webhook signature before processing the event.

The server should retain the GitHub delivery ID.

Use it for idempotency.

Example unique constraint:

```text
github_event_id UNIQUE
```

This prevents duplicate webhook delivery from launching duplicate agents.

---

# 10. Initial Trigger Logic

The first evaluator should intentionally be simple.

Pseudo logic:

```text
if event.type != issues
    ignore

if action != labeled
    ignore

if label != agent:run
    ignore

repository = findConfiguredRepository()

if repository == null
    ignore

if existingRunForDelivery()
    ignore

createRun()

launchRun()
```

Later this can become the full rule engine shown in the UI mockups.

Do not implement the generalized rule engine until the vertical slice is proven.

---

# 11. Agent Sandbox Container

Build one initial container image containing everything required by both agents.

Example:

```text
ghcr.io/<org>/sandcastle-agent:latest
```

The image should contain:

```text
git
bash
curl
jq
node
python
Claude Code CLI
Codex CLI
Engram client/tools
Sand Castle bootstrap script
```

Engram client/tools is not in the image yet; §41 covers when it is added.

Do not build one Kubernetes image per Run.

The image should be immutable.

Run-specific configuration arrives through:

- environment variables
- Secrets
- ConfigMaps
- command arguments

---

# 12. Container Entrypoint

Create a Sand Castle bootstrap executable instead of starting Claude directly.

Example:

```text
/usr/local/bin/sandcastle-run
```

Responsibilities:

```text
1. validate environment
2. create workspace
3. clone repository
4. configure git
5. initialize Engram
6. obtain issue context
7. launch selected agent
8. capture exit code
9. collect output
10. optionally push changes
11. report completion
```

Conceptual shell:

```text
sandcastle-run
    │
    ├── prepareWorkspace()
    ├── checkoutRepository()
    ├── configureEngram()
    ├── configureAgentAuth()
    ├── runAgent()
    ├── runValidation()
    ├── persistArtifacts()
    └── reportResult()
```

Keep orchestration logic in this wrapper rather than embedding it into giant Kubernetes commands.

---

# 13. Claude Authentication

This is an important constraint.

Sand Castle is **not calling the Anthropic API** for agent execution.

The workload launches:

```text
Claude Code CLI
```

using OAuth credentials supplied to the CLI environment.

Conceptually:

```text
Pod
  │
  └── Claude CLI
        │
        └── OAuth credential
```

not:

```text
Sand Castle
  │
  └── Anthropic API
```

This distinction should remain explicit throughout the system.

---

# 14. OAuth Secret Handling

OAuth credentials must live in Kubernetes Secrets.

Example:

```text
Secret
sandcastle-claude-oauth
```

The container receives only the environment/files expected by the installed Claude CLI authentication mechanism.

Sand Castle itself should generally know only:

```text
secret name
secret key
credential type
```

not the credential value.

The browser must never receive OAuth token values.

The database must never persist them.

Application logs must never include them.

---

# 15. Secret References

Repository or agent configuration should store references.

Example:

```json
{
  "agent": "claude",
  "credential": {
    "type": "kubernetes-secret",
    "name": "sandcastle-claude-oauth",
    "key": "token"
  }
}
```

The Kubernetes runtime translates this to Pod configuration.

Conceptually:

```yaml
env:
  - name: CLAUDE_OAUTH_TOKEN
    valueFrom:
      secretKeyRef:
        name: sandcastle-claude-oauth
        key: token
```

The exact environment/file arrangement should match the authentication interface expected by the CLI version installed in the agent image.

Keep this behind an adapter so auth details can change without affecting Run orchestration.

---

# 16. Agent Authentication Adapter

Define:

```text
AgentCredentialProvider
```

Interface:

```text
configure(agent, podSpec)
```

Implement:

```text
ClaudeOAuthCredentialProvider
CodexOAuthCredentialProvider
```

This avoids scattering token-specific assumptions throughout the Kubernetes layer.

---

# 17. GitHub Authentication

The agent also needs GitHub access.

Use a dedicated credential.

Preferably:

```text
GitHub App installation token
```

Eventually.

For the initial slice, a scoped GitHub token may be simpler.

The agent needs enough access to:

- clone repository
- create branch
- push branch
- comment on issue
- potentially create PR

Avoid passing the Sand Castle server's own full-permission credential if possible.

---

# 18. Kubernetes Runtime Interface

Define a generic runtime boundary early.

```text
interface SandboxRuntime {
    create(run): SandboxHandle
    get(run): SandboxStatus
    stop(run)
    logs(run)
    cleanup(run)
}
```

Implementation:

```text
KubernetesSandboxRuntime
```

This gives room for future runtimes:

```text
DockerRuntime
LocalRuntime
FirecrackerRuntime
RemoteSandboxRuntime
```

without redesigning the Run model.

---

# 19. Kubernetes Workload Type

For the vertical slice, use a **Pod** or **Job**.

Prefer:

```text
Job
```

because an agent run is naturally finite.

Benefits:

- explicit completion state
- retry controls
- TTL cleanup
- historical state
- well-defined exit status

Architecture:

```text
Run
  │
  ▼
Kubernetes Job
  │
  ▼
Pod
```

The UI can still present the runtime as a Sandbox.

---

# 20. Example Job

Conceptually:

```yaml
apiVersion: batch/v1
kind: Job

metadata:
  name: sandcastle-<run-id>

spec:
  backoffLimit: 0

  ttlSecondsAfterFinished: 3600

  template:
    metadata:
      labels:
        app: sandcastle
        sandcastle.run: <run-id>

    spec:
      restartPolicy: Never

      containers:
        - name: agent

          image: ghcr.io/.../sandcastle-agent:<digest>

          env:
            - name: SANDCASTLE_RUN_ID
              value: ...

            - name: GITHUB_REPOSITORY
              value: ...

            - name: GITHUB_ISSUE_NUMBER
              value: ...

            - name: AGENT
              value: claude

            - name: GITHUB_TOKEN
              valueFrom: ...

            - name: CLAUDE_OAUTH_TOKEN
              valueFrom: ...

            - name: ENGRAM_URL
              valueFrom: ...

          resources:
            requests:
              cpu: "1"
              memory: "2Gi"

            limits:
              cpu: "2"
              memory: "4Gi"
```

Use immutable image digests in production.

---

# 21. Namespace

Use a dedicated namespace:

```text
sandcastle-agents
```

The Sand Castle server itself can live separately:

```text
sandcastle-system
```

This gives a clean security boundary.

Example:

```text
sandcastle-system
    sandcastle-server
    sandcastle-ui
    postgres

sandcastle-agents
    run-abc123
    run-def456
```

---

# 22. Kubernetes RBAC

The Sand Castle backend should receive the minimum permissions needed in:

```text
sandcastle-agents
```

Likely:

```text
create jobs
get jobs
list jobs
watch jobs
delete jobs

get pods
list pods
watch pods

get pod logs
```

Shell access later may require:

```text
pods/exec
```

Do not grant cluster-admin.

---

# 23. Resource Limits

Every agent workload must have limits.

Initial defaults:

```text
CPU request: 500m
CPU limit: 2

Memory request: 1Gi
Memory limit: 4Gi

Run timeout: 30 minutes
```

These should become configurable later.

---

# 24. Workspace

Initial workspace:

```text
/workspace
```

For the vertical slice use:

```text
emptyDir
```

Example:

```yaml
volumes:
  - name: workspace
    emptyDir: {}
```

The workspace does not need to survive successful execution.

Persistent artifacts belong outside the Pod.

---

# 25. Repository Checkout

The bootstrap process should:

```text
mkdir /workspace/repo

git clone repository

cd repository

create run branch
```

Branch naming convention:

```text
sandcastle/issue-142
```

or:

```text
sandcastle/<run-id>
```

Prefer the Run ID for uniqueness:

```text
sandcastle/run-abc123
```

Store issue association separately.

---

# 26. Agent Prompt Construction

Sand Castle should provide the agent with structured context rather than simply saying:

```text
solve issue #142
```

Construct a task instruction containing:

```text
Repository
Issue number
Issue title
Issue body
Relevant labels
Run ID
Repository instructions
Expected completion behavior
Testing expectations
```

Example conceptual prompt:

```text
You are working inside a Sand Castle agent sandbox.

Repository:
pmhood/level-zero

GitHub Issue:
#142 Add authentication middleware

Task:
<issue body>

Requirements:

- inspect the repository before changing code
- implement the issue
- run relevant tests
- do not modify unrelated code
- leave the repository in a clean working state
- summarize the work performed
```

Agent-specific wrapper code can translate this into the invocation expected by Claude or Codex.

---

# 27. Agent Adapter

Define:

```text
AgentRunner
```

Example:

```text
run(taskContext): AgentResult
```

Implement:

```text
ClaudeCodeRunner
CodexRunner
```

The bootstrap program chooses the implementation from:

```text
AGENT=claude
```

or:

```text
AGENT=codex
```

This prevents Claude CLI-specific behavior from becoming the overall execution architecture.

---

# 28. Engram Integration

For the vertical slice, keep Engram integration minimal.

The goal is simply to verify:

```text
agent workload
       │
       ▼
     Engram
```

works from within the sandbox.

Store enough metadata to correlate memory to:

```text
repository
run
issue
```

Example logical scope:

```text
repository:
pmhood/level-zero

workspace:
issue-142

run:
run-abc123
```

Avoid building elaborate memory management UI in the first milestone.

---

# 29. Sand Castle Callback

The agent Pod needs a reliable way to tell Sand Castle what happened.

There are two viable models.

## Model A — Kubernetes observer

Sand Castle watches:

```text
Job
Pod
Logs
Exit code
```

The server derives the result.

This is simplest operationally.

## Model B — explicit callback

Bootstrap sends:

```text
POST /internal/runs/:id/result
```

with:

```json
{
  "status": "completed",
  "summary": "...",
  "branch": "...",
  "commit": "..."
}
```

Recommended initial design:

**Use both.**

The callback communicates rich agent results.

Kubernetes Job status remains the source of truth for workload termination.

---

# 30. Internal Authentication

The callback endpoint must not be public without authentication.

The Pod can receive a short-lived Run token.

Example:

```text
SANDCASTLE_RUN_TOKEN
```

Generated specifically for:

```text
run-abc123
```

The server validates it for:

```text
/internal/runs/run-abc123/*
```

Do not reuse GitHub or Claude credentials.

---

# 31. Logging

Logs should initially come directly from Kubernetes container stdout/stderr.

Structure log prefixes where possible:

```text
[SANDCASTLE]
[GIT]
[ENGRAM]
[CLAUDE]
[TEST]
[GITHUB]
```

Example:

```text
[SANDCASTLE] Run run-abc123 started
[GIT] Cloning repository
[ENGRAM] Workspace initialized
[CLAUDE] Starting Claude Code CLI
[CLAUDE] Reading repository
[TEST] npm test
[GITHUB] Pushing branch
```

The backend can stream Pod logs to the UI.

---

# 32. Real-Time UI

For the MVP, use Server-Sent Events.

Example:

```text
GET /api/runs/:id/events
```

Events:

```text
run.state
run.stage
log
resource
completed
failed
```

SSE is sufficient because communication is primarily server → browser.

WebSockets can be introduced later if interactive shell support becomes important.

---

# 33. Initial API

Keep the API small.

## Runs

```text
GET /api/runs

GET /api/runs/:id

GET /api/runs/:id/logs

GET /api/runs/:id/events

POST /api/runs/:id/stop
```

---

## Repositories

```text
GET /api/repositories

POST /api/repositories

GET /api/repositories/:id
```

---

## GitHub

```text
POST /api/github/webhook
```

---

# 34. Initial UI

The first UI should only contain enough functionality to observe the vertical slice.

Build:

## Runs page

```text
Status
Issue
Repository
Agent
Started
Duration
```

## Run detail

```text
Issue → Trigger → Sandbox → Kubernetes → Agent → Result
```

## Logs

Streaming logs.

## Inspector

```text
Run ID
Job
Pod
Image
Agent
Start time
Duration
Environment status
```

## Actions

```text
Stop Run
Open GitHub
```

Do not initially build:

- image administration
- general cluster dashboard
- sophisticated trigger builder
- configuration dashboard
- metrics charts
- artifact browser

Those come after the first slice works.

---

# 35. Vertical Slice Build Order

Build in this exact order.

## Phase 1 — Agent image

Create the container image manually.

Prove it can:

```text
docker run
    ↓
Claude Code CLI
    ↓
OAuth authentication
    ↓
repository checkout
```

Do not involve Sand Castle yet.

Success criteria:

Claude CLI works non-interactively inside the container with the supplied OAuth credentials.

This is the most important technical risk to eliminate first.

---

# 36. Phase 2 — Kubernetes execution

Deploy the same container manually as a Kubernetes Job.

Provide:

```text
OAuth Secret
GitHub Secret
repository
issue
```

Verify:

```text
kubectl create job
    ↓
agent runs
    ↓
changes repository
    ↓
job exits
```

At this point there is still no Sand Castle server.

This proves:

```text
OAuth + CLI + Kubernetes
```

independently.

---

# 37. Phase 3 — Sand Castle launches Job

Build:

```text
POST /api/test-runs
```

The backend creates the Kubernetes Job.

The request may initially look like:

```json
{
  "repository": "pmhood/level-zero",
  "issue": 142,
  "agent": "claude"
}
```

Success criteria:

```text
HTTP request
    ↓
Sand Castle
    ↓
Kubernetes Job
    ↓
Claude
```

---

# 38. Phase 4 — Observe execution

Add:

```text
Run persistence
Job watcher
Pod watcher
Logs
Run states
```

The UI should now display:

```text
creating
starting
running
completed
failed
```

---

# 39. Phase 5 — GitHub webhook

Connect:

```text
GitHub label
    ↓
webhook
    ↓
Sand Castle
    ↓
Run
```

Use only:

```text
agent:run
```

Initially.

---

# 40. Phase 6 — GitHub result

When successful:

```text
commit
push branch
comment on issue
```

Example result:

```text
Sand Castle completed this run.

Branch:
sandcastle/run-abc123

Tests:
Passed

Summary:
Implemented authentication middleware.
```

Optionally create a PR later.

---

# 41. Phase 7 — Engram

Once agent execution is stable, add Engram into the same flow.

Verify:

```text
Run starts
    ↓
Engram context available
    ↓
agent execution
    ↓
memory/context updated
```

Engram should not block proving the Kubernetes execution path.

---

# 42. First Acceptance Test

Create a deliberately simple issue.

Example:

```text
Issue #1

Add a file called sandcastle-test.txt containing:

Sand Castle works.
```

Add:

```text
agent:run
```

Expected result:

```text
Webhook received
Run created
Job created
Claude starts
Repo cloned
File created
Commit created
Branch pushed
Issue commented
Run completed
Job exits
```

Only after this works should the test become more complicated.

---

# 43. Second Acceptance Test

Ask Claude to perform an actual code change.

Example:

```text
Add GET /health endpoint returning:

{
  "status": "ok"
}

Add a test for the endpoint.
```

Verify:

```text
agent understands repository
implementation works
tests run
branch pushed
summary produced
```

---

# 44. Third Acceptance Test

Test failure handling.

Create an issue that cannot succeed.

Verify:

```text
Run → failed

exit code retained

logs available

issue receives failure comment

Pod retained temporarily

OAuth token not leaked
```

Failure UX is equally important to success UX.

---

# 45. Fourth Acceptance Test

Duplicate the same webhook delivery.

Verify only one Run exists.

This validates idempotency.

---

# 46. Fifth Acceptance Test

Stop a running Run.

Expected behavior:

```text
POST /runs/:id/stop
       │
       ▼
delete/cancel Kubernetes Job
       │
       ▼
Run = cancelled
```

The agent must not remain running afterward.

---

# 47. Cleanup Policy

For development:

```text
successful Job:
retain 1 hour

failed Job:
retain 24 hours
```

Later make this configurable.

Use:

```text
ttlSecondsAfterFinished
```

where appropriate.

The Run record itself remains in PostgreSQL.

---

# 48. Observability

The server should emit structured logs.

Always include:

```text
run_id
repository
issue
sandbox_id
job_name
pod_name
agent
```

Example:

```json
{
  "event": "agent.started",
  "run_id": "run-abc123",
  "agent": "claude",
  "pod": "sandcastle-run-abc123-x7fhq"
}
```

This will map nicely to OpenTelemetry later.

---

# 49. Metrics to Add After Vertical Slice

Once it works, add:

```text
runs_started_total
runs_completed_total
runs_failed_total

run_duration_seconds

sandbox_start_duration_seconds

agent_duration_seconds

active_runs
```

Avoid spending time building metrics before the first successful Run.

---

# 50. Security Boundaries

Treat the agent container as potentially unsafe code execution.

An agent can:

- execute shell commands
- modify files
- run repository scripts
- interact with GitHub

Therefore:

```text
agent namespace
      ≠
Sand Castle system namespace
```

Use:

- dedicated ServiceAccount
- no Kubernetes API token unless needed
- read-only root filesystem where practical
- non-root user
- restricted capabilities
- CPU/memory limits
- NetworkPolicy
- scoped GitHub token

The agent should not automatically receive access to the Sand Castle Kubernetes API.

---

# 51. Network Policy

The agent likely needs outbound access to:

```text
GitHub
Claude authentication/service endpoints used by Claude CLI
Codex/OpenAI endpoints used by Codex CLI
Engram
package registries
```

It generally should NOT reach:

```text
Kubernetes API
Sand Castle Postgres
other agent Pods
internal cluster workloads
```

Start permissive enough to prove the system, then tighten deliberately.

---

# 52. OAuth Handling Rule

The architecture must preserve this distinction:

```text
OAuth token
    ↓
Claude Code CLI
```

The Sand Castle server does not translate the OAuth token into Anthropic API calls.

Sand Castle's responsibilities are only:

```text
select credential
inject credential
launch CLI
observe CLI
```

The CLI remains responsible for provider communication.

The same pattern applies to Codex.

---

# 53. Architecture After Vertical Slice

Once the complete path is proven, evolve toward:

```text
                       GitHub
                          │
                          ▼
                  Trigger Controller
                          │
                          ▼
                     Run Manager
                          │
                  ┌───────┴────────┐
                  ▼                ▼
            Sandbox Service     Run Store
                  │
                  ▼
             Runtime Layer
                  │
       ┌──────────┴──────────┐
       ▼                     ▼
 Kubernetes Runtime      Future Runtime
       │
       ▼
 Agent Sandbox
       │
 ┌─────┴─────────────┐
 ▼                   ▼
Claude              Codex
 │                   │
 └─────────┬─────────┘
           ▼
         Engram
```

Only introduce additional abstractions when the working system creates a reason for them.

---

# 54. Potential Future AgentRun CRD

Do **not** build this first.

If Sand Castle eventually becomes Kubernetes-native enough to justify it, a CRD could represent:

```yaml
apiVersion: sandcastle.dev/v1
kind: AgentRun

spec:
  repository: pmhood/level-zero

  issue:
    number: 142

  agent:
    type: claude

  sandbox:
    image: ghcr.io/...@sha256:...

    resources:
      cpu: 2
      memory: 4Gi

status:
  phase: Running
  stage: Agent

  sandboxId: sbx-a91c

  pod:
    name: agent-a91c
```

But a database-backed application model is substantially simpler for the proof.

---

# 55. Recommended Repository Structure

```text
sandcastle/

├── apps/
│
│   ├── server/
│   │   └── Sand Castle API + orchestration
│   │
│   └── web/
│       └── React UI
│
├── packages/
│
│   ├── domain/
│   │   └── Run / Repository / Trigger types
│   │
│   ├── github/
│   │
│   ├── runtime/
│   │   └── SandboxRuntime interface
│   │
│   ├── agent/
│   │   ├── AgentRunner
│   │   ├── Claude runner
│   │   └── Codex runner
│   │
│   └── engram/
│
├── images/
│
│   └── agent/
│       ├── Dockerfile
│       ├── bootstrap/
│       └── scripts/
│
├── deploy/
│
│   ├── kubernetes/
│   └── helm/
│
└── docs/
    ├── DESIGN_SPEC.md
    └── ARCHITECTURE.md
```

---

# 56. The First Deliverable

The first deliverable should **not** be the Sand Castle dashboard.

It should be:

```text
GitHub Issue
      │
 add agent:run
      │
      ▼
Sand Castle Backend
      │
      ▼
Kubernetes Job
      │
      ▼
Claude Code CLI
      │
      ▼
Repository Change
      │
      ▼
GitHub Result
```

with a minimal page that shows:

```text
Run #abc123

Issue #142
Agent Claude

✓ GitHub Event
✓ Trigger
✓ Sandbox
✓ Kubernetes
● Agent
○ Result

Logs:
...

[ Stop Run ]
```

When that pipeline works reliably, the architecture has been validated.

Everything represented in the larger Sand Castle mockups can then grow outward from a proven core instead of being built ahead of the underlying system.

---

# 57. Definition of Done for the Vertical Slice

The vertical slice is complete when all of the following are true:

- A GitHub Issue label can launch a Run.
- Duplicate webhook deliveries do not launch duplicate Runs.
- Sand Castle creates a Kubernetes Job.
- The Job uses the configured agent image.
- Claude Code CLI authenticates via OAuth inside the container.
- No Anthropic API key is required by Sand Castle.
- GitHub credentials are injected securely.
- The repository is cloned into an isolated workspace.
- Claude receives issue context.
- Claude can modify the repository.
- Claude can execute tests/commands.
- Sand Castle streams logs while the agent is running.
- Sand Castle knows when the Job finishes.
- Successful Runs can push their output to GitHub.
- Failed Runs preserve useful diagnostics.
- OAuth credentials never appear in the UI, database, or logs.
- Runs can be cancelled.
- Completed workloads are cleaned up.
- Run history remains visible after the Pod is deleted.

Only after this milestone should the team build the broader Sand Castle control plane.
