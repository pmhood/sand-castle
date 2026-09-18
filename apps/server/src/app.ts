// The Sand Castle server, as a Fastify instance with its routes registered and nothing started
// (docs/ARCHITECTURE.md §5: one deployable backend service, not a set of microservices).
//
// Building and listening are separate so a test can build the same app the process runs and
// bind it to an ephemeral port. src/main.ts is the only caller that listens.
//
// `buildApp` takes the SandboxRuntime that POST /api/test-runs needs (src/api/test-runs.ts) as
// a plain required parameter, rather than constructing one itself. That is the test seam #51's
// SandboxRuntime interface exists for (see sandbox/runtime.ts's own header): a test passes a
// fake that never touches a cluster, and src/main.ts passes a real KubernetesSandboxRuntime.
// There is exactly one route that needs it, so a constructor-style parameter is the whole
// mechanism -- no DI container, no service locator, no plugin registry to wire it through.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify'
import { registerTestRunsRoute } from './api/test-runs.ts'
import type { SandboxRuntime } from './sandbox/runtime.ts'

/** `GET /health` (§5, module `api/health`). */
export interface HealthResponse {
    status: 'ok'
}

export function buildApp(
    runtime: SandboxRuntime,
    options: FastifyServerOptions = {},
): FastifyInstance {
    const app = Fastify({
        ...options,
        // Fastify's default AJV instance coerces types, applies schema defaults, and silently
        // drops properties a schema did not declare (coerceTypes, useDefaults, removeAdditional
        // all default to true). Left on, src/api/test-runs.ts's schema would stop meaning what
        // it says: a numeric string would pass an `integer` check, and an unexpected field --
        // an OAuth token, say -- would be quietly stripped and the request accepted instead of
        // refused. Off, so "malformed" means rejected with a 400, never silently repaired.
        ajv: {
            customOptions: { coerceTypes: false, removeAdditional: false, useDefaults: false },
        },
    })

    app.get('/health', (): HealthResponse => ({ status: 'ok' }))
    registerTestRunsRoute(app, runtime)

    return app
}
