// KubernetesSandboxRuntime.create, exercised against a fake BatchClient (#28's lesson, applied
// here rather than to a bash query).
//
// #28's fake `kubectl` picked its answer by matching a substring of the query, so a typo in the
// real code still matched something plausible and 31 tests passed against a broken launcher;
// #41 then found that the fix's own guard could be fooled the same way. The fakes below are
// built the other way around: each is told exactly one namespace it may be called for, and
// anything else -- the wrong namespace, or a namespace that was never configured -- throws an
// error stamped "FAKE MISUSE", a string no real Kubernetes response ever produces. The first
// test below calls create() against a fake configured for the wrong namespace and asserts on
// that exact message, so the guard is demonstrated, not just asserted to exist.

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { ApiException, type V1Job } from '@kubernetes/client-node'
import {
    KubernetesSandboxRuntime,
    type BatchClient,
} from '../../src/kubernetes/kubernetes-sandbox-runtime.ts'
import type { SandboxCreateInput } from '../../src/sandbox/runtime.ts'

const INPUT: SandboxCreateInput = { repository: 'octocat/Hello-World', issue: 7, agent: 'claude' }
const NAMESPACE = 'sandcastle-agents'
const RUN_ID_IN_JOB_NAME = /^sandcastle-run-\d{8}-\d{6}-[0-9a-f]{6}$/

interface CapturedCall {
    namespace: string
    body: V1Job
}

/**
 * A BatchClient whose createNamespacedJob only answers for `expectedNamespace`; any other
 * namespace throws a FAKE MISUSE error instead of returning something a passing test could
 * mistake for success. See the file header for why that -- not the scripted outcome below -- is
 * the point of this fake.
 */
function fakeBatchClient(
    expectedNamespace: string,
    outcome: { succeeds: true } | { succeeds: false; error: Error },
): BatchClient & { readonly calls: readonly CapturedCall[] } {
    const calls: CapturedCall[] = []

    return {
        calls,
        createNamespacedJob(params: { namespace: string; body: V1Job }): Promise<V1Job> {
            if (params.namespace !== expectedNamespace) {
                return Promise.reject(
                    new Error(
                        `FAKE MISUSE: createNamespacedJob called for namespace '${params.namespace}', ` +
                            `but this fake only expects '${expectedNamespace}'`,
                    ),
                )
            }
            calls.push({ namespace: params.namespace, body: params.body })
            return outcome.succeeds ? Promise.resolve(params.body) : Promise.reject(outcome.error)
        },
    }
}

test('the fake rejects a call it was not told to expect', async () => {
    // job-builder.ts always renders 'sandcastle-agents' (§21); configuring the fake for a
    // different namespace means the real call create() makes cannot match it.
    const client = fakeBatchClient('a-namespace-this-fake-was-not-told-about', { succeeds: true })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), /FAKE MISUSE/)
    assert.equal(client.calls.length, 0, 'the misused call must not be recorded as a real one')
})

test('create submits the rendered Job to the namespace job-builder.ts renders and returns its name', async () => {
    const client = fakeBatchClient(NAMESPACE, { succeeds: true })
    const runtime = new KubernetesSandboxRuntime(client)

    const handle = await runtime.create(INPUT)

    assert.equal(client.calls.length, 1)
    const call = client.calls[0]
    assert.equal(call?.namespace, NAMESPACE)
    assert.match(handle.sandboxId, RUN_ID_IN_JOB_NAME)
    assert.equal(call?.body.metadata?.name, handle.sandboxId)
    assert.equal(call?.body.metadata?.namespace, NAMESPACE)

    // The handle names a real Job, not a guess at one: it is exactly what was submitted.
    const env = call?.body.spec?.template?.spec?.containers?.[0]?.env ?? []
    const envValue = (name: string): string | undefined =>
        env.find((entry) => entry.name === name)?.value
    assert.equal(envValue('GITHUB_REPOSITORY'), INPUT.repository)
    assert.equal(envValue('GITHUB_ISSUE_NUMBER'), String(INPUT.issue))
    assert.equal(envValue('AGENT'), INPUT.agent)
})

test('two calls to create mint two different run IDs', async () => {
    const client = fakeBatchClient(NAMESPACE, { succeeds: true })
    const runtime = new KubernetesSandboxRuntime(client)

    const first = await runtime.create(INPUT)
    const second = await runtime.create(INPUT)

    assert.notEqual(first.sandboxId, second.sandboxId)
})

// The three shapes the issue requires be distinguishable, each reproducing what the live k3s
// cluster actually returned when probed by hand (see the commit message): 403 Forbidden for the
// sandcastle-server identity acting outside its Role, 404 NotFound for a namespace that does not
// exist, and everything else -- an AlreadyExists conflict, here -- falling through to a generic
// "the API rejected this" message that still carries the server's own code, reason and message.

test('an RBAC denial is reported as such, naming the namespace and the RBAC manifests', async () => {
    const error = new ApiException(
        403,
        'Unknown API Status Code!',
        {
            reason: 'Forbidden',
            message:
                `jobs.batch is forbidden: User "system:serviceaccount:sandcastle-agents:sandcastle-server" ` +
                `cannot create resource "jobs" in API group "batch" in the namespace "${NAMESPACE}"`,
        },
        {},
    )
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.match(thrown.message, /RBAC denied/)
        assert.match(thrown.message, new RegExp(NAMESPACE))
        assert.match(thrown.message, /server-role\.yaml/)
        return true
    })
})

test('a missing namespace is reported as such, naming the manifest that creates it', async () => {
    const error = new ApiException(
        404,
        'Unknown API Status Code!',
        { reason: 'NotFound', message: `namespaces "${NAMESPACE}" not found` },
        {},
    )
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.match(thrown.message, /does not exist/)
        assert.match(thrown.message, /namespace\.yaml/)
        return true
    })
})

test('any other API rejection is reported with the server\'s own code, reason and message', async () => {
    const error = new ApiException(
        409,
        'Unknown API Status Code!',
        { reason: 'AlreadyExists', message: 'jobs.batch "sandcastle-run-x" already exists' },
        {},
    )
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.match(thrown.message, /409/)
        assert.match(thrown.message, /AlreadyExists/)
        assert.match(thrown.message, /already exists/)
        return true
    })
})

test('a call that never reached the API server is reported as the cluster being unreachable', async () => {
    // What @kubernetes/client-node actually throws for a connection failure is not an
    // ApiException -- there was no HTTP response to build one from.
    const error = new Error('connect ECONNREFUSED 127.0.0.1:6443')
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.match(thrown.message, /cannot reach the Kubernetes cluster/)
        assert.match(thrown.message, /ECONNREFUSED/)
        return true
    })
})

test('classification reads only reason and message, never the rest of the response body', async () => {
    // A field alongside reason/message that a real API error could carry -- e.g. `details`
    // echoing part of the request. If classifyFailure ever started stringifying the whole body,
    // this would leak into the thrown message; it must not.
    const marker = 'this-must-never-appear-in-the-thrown-message'
    const error = new ApiException(
        500,
        'Unknown API Status Code!',
        { reason: 'InternalError', message: 'the server failed', details: { cause: marker } },
        {},
    )
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.doesNotMatch(thrown.message, new RegExp(marker))
        return true
    })
})

test('no credential Secret reference or value appears in a failure message', async () => {
    const error = new ApiException(500, 'Unknown API Status Code!', { reason: 'InternalError' }, {})
    const client = fakeBatchClient(NAMESPACE, { succeeds: false, error })
    const runtime = new KubernetesSandboxRuntime(client)

    await assert.rejects(runtime.create(INPUT), (thrown: unknown) => {
        assert.ok(thrown instanceof Error)
        assert.doesNotMatch(thrown.message, /TOKEN|OAUTH|SECRET|PASSWORD|CREDENTIAL/)
        return true
    })
})
