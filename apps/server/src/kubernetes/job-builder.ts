// The agent Job manifest, built in the server (docs/ARCHITECTURE.md §19, §20, §21, §23, §50).
//
// §5's module list calls this `kubernetes/pod-builder`; the workload is a Job rather than a bare
// Pod (§19), so the file is named for what it builds. It returns a plain object for the
// Kubernetes API, and does nothing with it: submitting is #53, and the HTTP endpoint above that
// is #55.
//
// ## Two renderers, deliberately, for Phase 3
//
// deploy/kubernetes/scripts/render-job.sh renders this same manifest out of
// deploy/kubernetes/job.yaml, and it is not going away in this issue. It is what Phase 2 runs
// today: launch-run.sh, validate.sh and prove-checks.sh all go through it, none of them has a
// server to ask, and an operator holding a broken cluster should not need a TypeScript build
// between themselves and `kubectl apply`. Retiring it here would break a working path this issue
// is not about.
//
// Two renderers of one manifest is also exactly the shape #26 was filed for -- two readers of one
// file that drifted apart and were found out by an operator. So the coexistence is bounded by a
// test rather than by intentions: test/kubernetes/job-builder.test.ts runs render-job.sh for
// real, parses what it printed, and asserts it equals what this function returns, field for
// field. The two cannot diverge without that test going red, and neither can this file's copy of
// the image digest.
//
// Convergence: once #53 submits this manifest and §37's `POST /api/test-runs` is the way a run
// starts, the bash renderer becomes the manual fallback for a cluster with no server on it, and
// this becomes the renderer every run goes through. That is the point at which to decide whether
// job.yaml survives as a template or as documentation -- not before, while deleting it would
// leave Phase 2 with no way to start a run at all. deploy/kubernetes/README.md records the same
// decision from the other side.
//
// ## Credentials
//
// Nothing here reads, translates or logs a credential (§14, §52). The two the run needs arrive as
// `secretKeyRef` entries naming Secrets an operator created with create-secrets.sh (§15/§16), so
// the object this returns holds no credential value to leak -- §57's "never in logs" is a
// property of the manifest's shape here, not of a redaction step someone has to remember.

import type { SandboxCreateInput } from '../sandbox/runtime.ts'

/**
 * What one Job needs. The run identity is an input rather than something minted here: a run ID
 * belongs to the run, and #53 -- which has to hand the same ID back to its caller as a
 * SandboxHandle -- is where it gets chosen.
 */
export interface AgentJobInput extends SandboxCreateInput {
    runId: string
}

const NAMESPACE = 'sandcastle-agents'

// §20 and #18: an immutable digest, never a floating tag. This is the same reference job.yaml
// pins, and images/agent/README.md ("Getting the current digest") documents how to update it --
// both lines move together, and the equivalence test fails if only one of them does.
const AGENT_IMAGE =
    'ghcr.io/pmhood/sandcastle-agent@sha256:de6e6b925d00f798f22d63015ceeaf90b703ac6cb28396ba709917fc97cf1479'

// `sandcastle-<run-id>` must be a DNS-1123 label, and a label value, so at most 63 characters.
// The same limits render-job.sh enforces, for the same reason: a Job named `sandcastle-` is
// rejected by the API server at best and collides with the next empty one at worst.
const RUN_ID_PATTERN = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/
const RUN_ID_MAX_LENGTH = 52

// Exported so src/api/test-runs.ts can reject a malformed `repository` in the same shape,
// before the request reaches this file's own check -- one pattern, not two copies that could
// drift the way #26 was filed over.
export const REPOSITORY_PATTERN = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/

/**
 * Rejects an input the manifest cannot carry, before it becomes a Job the API server refuses or
 * -- worse -- accepts. The shapes are render-job.sh's, and the bootstrap's `validateEnvironment`
 * checks them a third time inside the container; agreeing with both is the point.
 */
function validateInput(input: AgentJobInput): void {
    if (!RUN_ID_PATTERN.test(input.runId)) {
        throw new Error(
            `run ID '${input.runId}' is not a DNS-1123 label (lower-case letters, digits and hyphens)`,
        )
    }
    if (input.runId.length > RUN_ID_MAX_LENGTH) {
        throw new Error(
            `run ID '${input.runId}' is longer than ${String(RUN_ID_MAX_LENGTH)} characters`,
        )
    }
    if (!REPOSITORY_PATTERN.test(input.repository)) {
        throw new Error(`repository '${input.repository}' is not owner/repo`)
    }
    if (!Number.isInteger(input.issue) || input.issue < 1) {
        throw new Error(`issue '${String(input.issue)}' is not a positive integer`)
    }
    // The agent and its credential change together, which is why AGENT is a constant in job.yaml
    // rather than a fourth placeholder. There is no Codex Secret in the cluster -- create-secrets.sh
    // makes two, and neither is one -- so a Codex Job would start and then fail to authenticate.
    // Refusing beats rendering a reference to a Secret nobody has created.
    if (input.agent !== 'claude') {
        throw new Error(
            `agent '${input.agent}' has no credential Secret; see deploy/kubernetes/README.md ` +
                `("Running Codex instead of Claude") for what running it takes today`,
        )
    }
}

/**
 * One agent run as a Kubernetes Job, equivalent to `render-job.sh <runId> <repository> <issue>`.
 *
 * Every constant below is job.yaml's, and job.yaml carries the reasoning for each one -- why
 * `backoffLimit: 0`, why the node selector exists, why the TTL is the longer of §47's pair. Only
 * what is specific to building this in TypeScript is commented here; restating the rest would
 * give it two homes and one of them would go stale.
 */
export function buildAgentJob(input: AgentJobInput) {
    validateInput(input)

    return {
        apiVersion: 'batch/v1',
        kind: 'Job',
        metadata: {
            name: `sandcastle-${input.runId}`,
            namespace: NAMESPACE,
            labels: { app: 'sandcastle', 'sandcastle.run': input.runId },
        },
        spec: {
            backoffLimit: 0,
            activeDeadlineSeconds: 1800,
            ttlSecondsAfterFinished: 86400,
            template: {
                metadata: {
                    labels: { app: 'sandcastle', 'sandcastle.run': input.runId },
                },
                spec: {
                    restartPolicy: 'Never',
                    // A label selector value is a string; the quoting job.yaml needs to say so is
                    // this quoted 'true'. A boolean here is a Job the API server refuses.
                    nodeSelector: { 'sandcastle.dev/agent-capable': 'true' },
                    serviceAccountName: 'sandcastle-agent',
                    automountServiceAccountToken: false,
                    securityContext: {
                        runAsNonRoot: true,
                        runAsUser: 1000,
                        runAsGroup: 1000,
                        seccompProfile: { type: 'RuntimeDefault' },
                    },
                    containers: [
                        {
                            name: 'agent',
                            image: AGENT_IMAGE,
                            securityContext: {
                                allowPrivilegeEscalation: false,
                                readOnlyRootFilesystem: true,
                                capabilities: { drop: ['ALL'] },
                            },
                            // The run context the bootstrap's validateEnvironment requires, plus
                            // the two credentials it requires be present without ever reading
                            // them here. §20's example is stale on both sides: it writes
                            // CLAUDE_OAUTH_TOKEN, where the CLI in the image reads
                            // CLAUDE_CODE_OAUTH_TOKEN, and it lists an ENGRAM_URL that is Phase 7
                            // (§41) and that nothing in images/agent/bootstrap reads.
                            //
                            // Every value is a string, including the issue number: an env value
                            // is text, and a number here is refused exactly as an unquoted
                            // placeholder would be.
                            env: [
                                { name: 'SANDCASTLE_RUN_ID', value: input.runId },
                                { name: 'GITHUB_REPOSITORY', value: input.repository },
                                { name: 'GITHUB_ISSUE_NUMBER', value: String(input.issue) },
                                { name: 'AGENT', value: input.agent },
                                {
                                    name: 'GITHUB_TOKEN',
                                    valueFrom: {
                                        secretKeyRef: { name: 'sandcastle-github-token', key: 'token' },
                                    },
                                },
                                // Never `optional: true`, and never a literal `value` (#14, §15,
                                // §52): an optional reference to a missing key materialises as
                                // the empty string, and an empty CLAUDE_CONFIG_DIR is what made
                                // the CLI write into the checkout it was editing.
                                {
                                    name: 'CLAUDE_CODE_OAUTH_TOKEN',
                                    valueFrom: {
                                        secretKeyRef: { name: 'sandcastle-claude-oauth', key: 'token' },
                                    },
                                },
                            ],
                            // §23's initial defaults. Quantities are strings, as the API expects;
                            // `2` as a number is a different thing to the API server than `"2"`.
                            resources: {
                                requests: { cpu: '500m', memory: '1Gi' },
                                limits: { cpu: '2', memory: '4Gi' },
                            },
                            volumeMounts: [
                                { name: 'workspace', mountPath: '/workspace' },
                                { name: 'home', mountPath: '/home/node' },
                                { name: 'tmp', mountPath: '/tmp' },
                            ],
                        },
                    ],
                    volumes: [
                        { name: 'workspace', emptyDir: {} },
                        { name: 'home', emptyDir: {} },
                        { name: 'tmp', emptyDir: {} },
                    ],
                },
            },
        },
    }
}
