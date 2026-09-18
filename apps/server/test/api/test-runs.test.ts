// POST /api/test-runs, exercised over a real socket (the same choice health.test.ts makes, and
// for the same reason) against a fake SandboxRuntime, never a cluster.
//
// Two fakes, both built the way test/kubernetes/kubernetes-sandbox-runtime.test.ts's
// fakeBatchClient is: told exactly what call to expect, and answering anything else with an
// error stamped "FAKE MISUSE" -- a string no real success or classified failure ever produces.
//
//   - runtimeThatMustNotBeCalled rejects every method unconditionally. It backs every malformed-
//     or hostile-input test below: if src/api/test-runs.ts's schema ever stopped rejecting one
//     of these bodies, the request would reach this fake's create(), which would reject with
//     "FAKE MISUSE", which is not one of the four classified errors the route handler knows
//     about, so it would surface as 500 -- not the 400 the test asserts. The test fails whether
//     the validation gap sends a real call to a cluster or not; it does not depend on the fake
//     happening to throw in a way that looks like success.
//   - fakeSandboxRuntime(expectedInput, outcome) checks create()'s argument against exactly the
//     three fields a valid request should produce (and nothing else -- see its own comment) and
//     otherwise answers with a scripted success or a scripted classified error.

import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { FastifyInstance } from 'fastify'
import { buildApp } from '../../src/app.ts'
import {
    ApiRejectionError,
    ClusterUnreachableError,
    NamespaceMissingError,
    RbacDeniedError,
} from '../../src/kubernetes/kubernetes-sandbox-runtime.ts'
import type { SandboxCreateInput, SandboxHandle, SandboxRuntime } from '../../src/sandbox/runtime.ts'

const VALID_INPUT: SandboxCreateInput = { repository: 'pmhood/level-zero', issue: 142, agent: 'claude' }

function runtimeThatMustNotBeCalled(): SandboxRuntime {
    const fail = (method: string) => (): Promise<never> =>
        Promise.reject(new Error(`FAKE MISUSE: a rejected request must not reach SandboxRuntime.${method}`))
    return { create: fail('create'), get: fail('get'), stop: fail('stop'), logs: fail('logs'), cleanup: fail('cleanup') }
}

interface CapturedCall {
    input: SandboxCreateInput
}

/**
 * A SandboxRuntime whose create() only answers for `expectedInput`, matched field by field
 * (including that there are exactly three of them) so a handler that forwarded an extra field,
 * dropped one, or passed the wrong value cannot pass this fake by accident.
 */
function fakeSandboxRuntime(
    expectedInput: SandboxCreateInput,
    outcome: { succeeds: true; sandboxId: string } | { succeeds: false; error: Error },
): SandboxRuntime & { readonly calls: readonly CapturedCall[] } {
    const calls: CapturedCall[] = []

    return {
        calls,
        create(input: SandboxCreateInput): Promise<SandboxHandle> {
            const matches =
                Object.keys(input).length === 3 &&
                input.repository === expectedInput.repository &&
                input.issue === expectedInput.issue &&
                input.agent === expectedInput.agent
            if (!matches) {
                return Promise.reject(
                    new Error(
                        `FAKE MISUSE: create called with ${JSON.stringify(input)}, this fake only expects ` +
                            JSON.stringify(expectedInput),
                    ),
                )
            }
            calls.push({ input })
            return outcome.succeeds
                ? Promise.resolve({ sandboxId: outcome.sandboxId })
                : Promise.reject(outcome.error)
        },
        get: () => Promise.reject(new Error('FAKE MISUSE: SandboxRuntime.get should not be called by this route')),
        stop: () => Promise.reject(new Error('FAKE MISUSE: SandboxRuntime.stop should not be called by this route')),
        logs: () => Promise.reject(new Error('FAKE MISUSE: SandboxRuntime.logs should not be called by this route')),
        cleanup: () =>
            Promise.reject(new Error('FAKE MISUSE: SandboxRuntime.cleanup should not be called by this route')),
    }
}

async function withApp(runtime: SandboxRuntime, run: (origin: string) => Promise<void>): Promise<void> {
    const app: FastifyInstance = buildApp(runtime)
    const origin = await app.listen({ host: '127.0.0.1', port: 0 })
    try {
        await run(origin)
    } finally {
        await app.close()
    }
}

function post(origin: string, body: unknown): Promise<Response> {
    return fetch(`${origin}/api/test-runs`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: typeof body === 'string' ? body : JSON.stringify(body),
    })
}

// A credential must appear in none of: a request log, a response, or an error (§52, §57). This
// suite cannot see the log, but every response body it reads is checked against this.
function assertNoCredentialLeak(body: unknown): void {
    assert.doesNotMatch(JSON.stringify(body), /token|oauth|secret|credential/i)
}

test('a valid request creates a Job and returns its identifier', async () => {
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: true, sandboxId: 'sandcastle-run-x' })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 201, `POST /api/test-runs returned ${String(response.status)}`)
        assert.deepEqual(await response.json(), { sandboxId: 'sandcastle-run-x' })
        assert.equal(runtime.calls.length, 1)
    })
})

// Each malformed or hostile body below must be rejected with 400 before it reaches the runtime.
// See the file header for what "rejected" is actually proven against.
const MALFORMED_BODIES: Record<string, unknown> = {
    'missing repository': { issue: 142, agent: 'claude' },
    'missing issue': { repository: 'pmhood/level-zero', agent: 'claude' },
    'missing agent': { repository: 'pmhood/level-zero', issue: 142 },
    'issue as a string': { repository: 'pmhood/level-zero', issue: '142', agent: 'claude' },
    'issue as a float': { repository: 'pmhood/level-zero', issue: 142.5, agent: 'claude' },
    'issue negative': { repository: 'pmhood/level-zero', issue: -1, agent: 'claude' },
    'issue zero': { repository: 'pmhood/level-zero', issue: 0, agent: 'claude' },
    'issue enormous': { repository: 'pmhood/level-zero', issue: 1e21, agent: 'claude' },
    'agent as a number': { repository: 'pmhood/level-zero', issue: 142, agent: 1 },
    'agent unsupported (codex has no credential Secret)': {
        repository: 'pmhood/level-zero',
        issue: 142,
        agent: 'codex',
    },
    'agent unsupported (unknown string)': { repository: 'pmhood/level-zero', issue: 142, agent: 'gemini' },
    'repository with path traversal': { repository: '../../etc/passwd', issue: 142, agent: 'claude' },
    'repository with a shell metacharacter': {
        repository: 'pmhood/level-zero; rm -rf /',
        issue: 142,
        agent: 'claude',
    },
    'repository with no slash': { repository: 'pmhood', issue: 142, agent: 'claude' },
    'repository as a number': { repository: 42, issue: 142, agent: 'claude' },
    'an unexpected extra field': { ...VALID_INPUT, oauthToken: 'super-secret-value-should-never-appear' },
    'body is an array, not an object': ['pmhood/level-zero', 142, 'claude'],
    'body is a string, not an object': 'pmhood/level-zero',
    'body is not valid JSON at all': '{not json',
}

for (const [name, body] of Object.entries(MALFORMED_BODIES)) {
    test(`rejects a request where ${name}`, async () => {
        await withApp(runtimeThatMustNotBeCalled(), async (origin) => {
            const response = await post(origin, body)

            assert.equal(
                response.status,
                400,
                `POST /api/test-runs with ${name} returned ${String(response.status)}, expected 400`,
            )
            assertNoCredentialLeak(await response.json())
        })
    })
}

test('an unexpected field is never echoed back in the rejection', async () => {
    await withApp(runtimeThatMustNotBeCalled(), async (origin) => {
        const response = await post(origin, { ...VALID_INPUT, oauthToken: 'super-secret-value-should-never-appear' })

        assert.equal(response.status, 400)
        const text = await response.text()
        assert.doesNotMatch(text, /super-secret-value-should-never-appear/)
    })
})

test('an RBAC denial is reported as 502, without the RBAC manifest detail a caller has no business reading', async () => {
    const error = new RbacDeniedError(
        "RBAC denied creating Job 'sandcastle-run-x' in namespace 'sandcastle-agents': see " +
            'deploy/kubernetes/server-role.yaml',
    )
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: false, error })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 502)
        const body: unknown = await response.json()
        assertNoCredentialLeak(body)
        assert.doesNotMatch(JSON.stringify(body), /server-role\.yaml|sandcastle-agents/)
    })
})

test('a missing namespace is reported as 502, without the namespace name', async () => {
    const error = new NamespaceMissingError(
        "namespace 'sandcastle-agents' does not exist -- apply deploy/kubernetes/namespace.yaml",
    )
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: false, error })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 502)
        const body: unknown = await response.json()
        assertNoCredentialLeak(body)
        assert.doesNotMatch(JSON.stringify(body), /namespace\.yaml|sandcastle-agents/)
    })
})

test('any other API rejection is reported as 502', async () => {
    const error = new ApiRejectionError(
        "the Kubernetes API rejected Job 'sandcastle-run-x' (HTTP 409, AlreadyExists): already exists",
    )
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: false, error })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 502)
        assertNoCredentialLeak(await response.json())
    })
})

test('an unreachable cluster is reported as 503, distinctly from a rejection', async () => {
    const error = new ClusterUnreachableError(
        "cannot reach the Kubernetes cluster to create Job 'sandcastle-run-x': connect ECONNREFUSED",
    )
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: false, error })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 503)
        const body: unknown = await response.json()
        assertNoCredentialLeak(body)
        assert.doesNotMatch(JSON.stringify(body), /ECONNREFUSED/)
    })
})

test('an error the runtime did not classify is a 500, not folded into 502', async () => {
    // Anything KubernetesSandboxRuntime.create can actually throw is one of the four classified
    // errors above (see classifyFailure in kubernetes-sandbox-runtime.ts) -- this simulates a
    // bug that threw something else, to prove the handler does not quietly relabel it as a
    // cluster rejection it never made.
    const error = new Error('something unrelated to Kubernetes broke')
    const runtime = fakeSandboxRuntime(VALID_INPUT, { succeeds: false, error })

    await withApp(runtime, async (origin) => {
        const response = await post(origin, VALID_INPUT)

        assert.equal(response.status, 500)
    })
})
