// The Sand Castle server, as a Fastify instance with its routes registered and nothing started
// (docs/ARCHITECTURE.md §5: one deployable backend service, not a set of microservices).
//
// Building and listening are separate so a test can build the same app the process runs and
// bind it to an ephemeral port. src/main.ts is the only caller that listens.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify'

/** The only endpoint so far (§5, module `api/health`). */
export interface HealthResponse {
    status: 'ok'
}

export function buildApp(options: FastifyServerOptions = {}): FastifyInstance {
    const app = Fastify(options)

    app.get('/health', (): HealthResponse => ({ status: 'ok' }))

    return app
}
