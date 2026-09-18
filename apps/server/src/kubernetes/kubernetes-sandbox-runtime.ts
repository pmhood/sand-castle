// KubernetesSandboxRuntime.create (docs/ARCHITECTURE.md §6, §18, §21, §22, §37).
//
// job-builder.ts renders the manifest; this submits exactly what it rendered, with no changes
// of its own. Splitting the two keeps the equivalence job-builder.test.ts enforces against
// render-job.sh meaningful -- a file that both built and submitted the Job would make it
// tempting to patch the object in flight, which is exactly the drift #26 was filed for.
//
// ## Credentials to the Kubernetes API
//
// `KubeConfig#loadFromDefault()` already implements both paths §37 asks for, in the order an
// operator expects: a `KUBECONFIG` env var, then `~/.kube/config`, then (only once neither
// exists) the in-cluster ServiceAccount token at
// /var/run/secrets/kubernetes.io/serviceaccount. A developer machine driving the k3s cluster
// takes the first path; the server running as a Pod, under the sandcastle-server identity
// server-serviceaccount.yaml/server-role.yaml/server-rolebinding.yaml grant (#54), takes the
// second. There is deliberately no branch here on an environment variable of this repo's own --
// the client's own fallback chain already is the "both paths" behaviour, and reimplementing it
// would just be a second, less-tested copy of the same decision.
//
// ## Namespace
//
// Not a constant or parameter here: the Job this submits already carries its namespace, in
// `job.metadata.namespace`, set once by job-builder.ts's own NAMESPACE constant (§21). Reading
// it off the rendered manifest -- rather than importing or re-declaring the same string --
// means the two can never disagree about where a Job lands.
//
// ## Error classification
//
// §36's launch-run.sh names the layer that broke; this does the same for the one call this
// issue makes. `@kubernetes/client-node` throws `ApiException` for any non-2xx response, with
// `.code` (HTTP status) and `.body` (the API server's own `Status` object: `reason`,
// `message`). Verified live against the k3s cluster (see the commit message for the exact
// commands): a missing namespace is 404 `NotFound`; the sandcastle-server identity acting
// outside its Role is 403 `Forbidden`; a name collision is 409 `AlreadyExists`, which -- like
// any other rejection this does not special-case -- falls through to the generic "API
// rejected" branch with the server's own code, reason and message. Anything that is not an
// `ApiException` at all -- connection refused, DNS failure, a malformed kubeconfig -- means the
// call never reached the API server, so that is classified as the cluster being unreachable
// rather than a rejection.
//
// Each of the four branches throws its own `Error` subclass (RbacDeniedError,
// NamespaceMissingError, ApiRejectionError, ClusterUnreachableError, all defined just below).
// #55's HTTP handler needs to map these to distinct status codes and cannot do that by matching
// substrings of a message meant for a log -- that would silently break the moment this file's
// wording changed. `instanceof` does not have that problem.
//
// One caveat worth recording rather than hiding: server-role.yaml scopes sandcastle-server's
// Role to the sandcastle-agents namespace only. If that namespace itself were ever deleted, its
// RoleBinding would go with it, and the *next* attempt to create a Job there would present as
// 403 Forbidden, not 404 NotFound -- Kubernetes checks authorization before it checks whether
// the target namespace exists, and a least-privilege identity has no authorization to fall back
// on once its own namespace is gone. The NotFound branch below still fires correctly for any
// identity with broader access (a developer's own kubeconfig, say), and the Forbidden message
// names the namespace, so this remains diagnosable -- but it is not a case where the two
// classifications are guaranteed distinct HTTP statuses under every identity.
//
// Never logged, on any path: the manifest, the kubeconfig, or the raw error object. Only the
// three string fields above are read out of it (§14, §52, §57) -- an `ApiException.body` is
// server-supplied JSON that could otherwise be dumped wholesale by an incautious `console.log`.

import { randomBytes } from 'node:crypto'
import { ApiException, BatchV1Api, KubeConfig } from '@kubernetes/client-node'
import { buildAgentJob } from './job-builder.ts'
import type { SandboxCreateInput, SandboxHandle, SandboxRuntime, SandboxStatus } from '../sandbox/runtime.ts'

/**
 * The slice of `BatchV1Api` `create` actually calls, typed as a `Pick` of the real class rather
 * than a hand-written interface. A hand-written shape can drift from the client's own signature
 * without anything noticing; `Pick` cannot -- if `@kubernetes/client-node` ever changes
 * `createNamespacedJob`'s parameters, this fails to compile instead of quietly accepting a fake
 * that no longer matches. test/kubernetes/kubernetes-sandbox-runtime.test.ts's fake satisfies
 * this same type, which is what makes an unrecognised call to it a compile error, not a guess.
 */
export type BatchClient = Pick<BatchV1Api, 'createNamespacedJob'>

function defaultBatchClient(): BatchClient {
    const kubeConfig = new KubeConfig()
    kubeConfig.loadFromDefault()
    return kubeConfig.makeApiClient(BatchV1Api)
}

// `run-<UTC timestamp>-<6 hex chars>`, the same shape generateRunId() in
// deploy/kubernetes/scripts/launch-run.sh produces, so a Job this server created is not visually
// distinct from one launch-run.sh created by hand. Well inside RUN_ID_MAX_LENGTH (52).
function generateRunId(): string {
    const now = new Date()
    const pad = (n: number): string => String(n).padStart(2, '0')
    const stamp =
        `${String(now.getUTCFullYear())}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}` +
        `-${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}`
    const random = randomBytes(3).toString('hex')
    return `run-${stamp}-${random}`
}

/** Reads only the fields §36-style classification needs out of a Kubernetes `Status` body. */
function statusFields(body: unknown): { reason?: string; message?: string } {
    if (typeof body !== 'object' || body === null) {
        return {}
    }
    const { reason, message } = body as { reason?: unknown; message?: unknown }
    return {
        reason: typeof reason === 'string' ? reason : undefined,
        message: typeof message === 'string' ? message : undefined,
    }
}

// One subclass per branch below, so #55's HTTP handler can tell the branches apart with
// `instanceof` instead of pattern-matching the message text this file already composes for the
// log. The message on each stays exactly what it was before these existed -- the assertions in
// this file's own test match on `.message`, and #55's tests match on type -- so nothing here
// changes what an operator sees, only what a caller can do with it programmatically.
export class RbacDeniedError extends Error {}
export class NamespaceMissingError extends Error {}
export class ApiRejectionError extends Error {}
export class ClusterUnreachableError extends Error {}

/**
 * Turns whatever `createNamespacedJob` rejected with into an `Error` naming the layer that
 * broke, in the fail()-message style launch-run.sh uses for the same call made from bash.
 */
function classifyFailure(error: unknown, jobName: string, namespace: string): Error {
    if (error instanceof ApiException) {
        const { reason, message } = statusFields(error.body)
        const said = message ?? `HTTP ${String(error.code)}`

        if (reason === 'Forbidden') {
            return new RbacDeniedError(
                `RBAC denied creating Job '${jobName}' in namespace '${namespace}': the caller's ` +
                    `ServiceAccount has no Role granting 'create' on Jobs there -- see ` +
                    `deploy/kubernetes/server-role.yaml and server-rolebinding.yaml (docs/ARCHITECTURE.md ` +
                    `§22). Kubernetes said: ${said}`,
            )
        }

        if (reason === 'NotFound') {
            return new NamespaceMissingError(
                `namespace '${namespace}' does not exist -- apply deploy/kubernetes/namespace.yaml. ` +
                    `Kubernetes said: ${said}`,
            )
        }

        return new ApiRejectionError(
            `the Kubernetes API rejected Job '${jobName}' (HTTP ${String(error.code)}` +
                `${reason !== undefined ? `, ${reason}` : ''}): ${said}`,
        )
    }

    const message = error instanceof Error ? error.message : String(error)
    return new ClusterUnreachableError(
        `cannot reach the Kubernetes cluster to create Job '${jobName}': ${message}`,
    )
}

/**
 * §18's runtime, submitting to the cluster (§6). Only `create` is implemented -- the other four
 * `SandboxRuntime` methods are Phase 4's (§38): watching a Job, reading its logs, stopping and
 * cleaning one up all need the Run persistence and watchers that phase adds, none of which
 * exists yet. They throw rather than silently succeeding or being left off the class, because
 * TypeScript requires every interface member to exist on an implementing class -- there is no
 * way to omit them and still have `KubernetesSandboxRuntime implements SandboxRuntime` type-check.
 */
export class KubernetesSandboxRuntime implements SandboxRuntime {
    private readonly batchClient: BatchClient

    constructor(batchClient: BatchClient = defaultBatchClient()) {
        this.batchClient = batchClient
    }

    async create(input: SandboxCreateInput): Promise<SandboxHandle> {
        const job = buildAgentJob({ ...input, runId: generateRunId() })
        const namespace = job.metadata.namespace
        const jobName = job.metadata.name

        try {
            await this.batchClient.createNamespacedJob({ namespace, body: job })
        } catch (error) {
            throw classifyFailure(error, jobName, namespace)
        }

        return { sandboxId: jobName }
    }

    // No `handle` parameter: nothing here reads it, and declaring one just to satisfy
    // SandboxRuntime's signature would need an eslint-disable or a leading underscore for what
    // is otherwise unused. A method implementation may take fewer parameters than the interface
    // it implements -- TypeScript still holds `KubernetesSandboxRuntime` to `SandboxRuntime`.
    get(): Promise<SandboxStatus> {
        return notImplemented('get')
    }

    stop(): Promise<void> {
        return notImplemented('stop')
    }

    logs(): Promise<string> {
        return notImplemented('logs')
    }

    cleanup(): Promise<void> {
        return notImplemented('cleanup')
    }
}

function notImplemented(method: string): never {
    throw new Error(
        `KubernetesSandboxRuntime.${method} is not implemented yet -- docs/ARCHITECTURE.md §38 ` +
            "(Phase 4, observing a run) is what implements it; this issue's scope is create() only.",
    )
}
