// The health endpoint, exercised over a real socket rather than through Fastify's `inject`
// helper: this is the one route there is, and a test that never binds a port proves less than
// one that does. Remove the route from src/app.ts and both assertions below fail.

import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import type { FastifyInstance } from 'fastify'
import { buildApp } from '../src/app.ts'
import type { SandboxRuntime } from '../src/sandbox/runtime.ts'

// /health has nothing to do with a sandbox; every method rejects with a distinguishable error,
// so if a future change ever made the health route reach into SandboxRuntime, that would fail
// loudly here rather than pass by coincidence.
function runtimeThatMustNotBeCalled(): SandboxRuntime {
    const fail = (method: string) => (): Promise<never> =>
        Promise.reject(new Error(`FAKE MISUSE: GET /health must not call SandboxRuntime.${method}`))
    return { create: fail('create'), get: fail('get'), stop: fail('stop'), logs: fail('logs'), cleanup: fail('cleanup') }
}

let app: FastifyInstance
let origin: string

before(async () => {
    // Loopback and port 0: the OS picks a free port, so the suite never collides with a server
    // the developer already has running and never listens on an address off the machine.
    app = buildApp(runtimeThatMustNotBeCalled())
    origin = await app.listen({ host: '127.0.0.1', port: 0 })
})

after(async () => {
    await app.close()
})

test('GET /health answers 200 with a JSON ok status', async () => {
    const response = await fetch(`${origin}/health`)

    assert.equal(response.status, 200, `GET ${origin}/health returned ${String(response.status)}`)
    assert.match(response.headers.get('content-type') ?? '', /^application\/json/)
    assert.deepEqual(await response.json(), { status: 'ok' })
})

test('an unrouted path answers 404, so the test above is not passing on a catch-all', async () => {
    const response = await fetch(`${origin}/not-a-route`)

    assert.equal(response.status, 404, `GET ${origin}/not-a-route returned ${String(response.status)}`)
})
