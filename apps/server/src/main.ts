// Process entrypoint: build the app and listen. Everything else lives in src/app.ts.

import { buildApp } from './app.ts'
import { KubernetesSandboxRuntime } from './kubernetes/kubernetes-sandbox-runtime.ts'

// 0.0.0.0 because the process is meant to run in a container, where binding the loopback
// address would make the port unreachable from outside the Pod.
const host = '0.0.0.0'
const port = Number(process.env['PORT'] ?? 3000)

// The only caller that needs the real thing: KubeConfig#loadFromDefault() picks up the
// sandcastle-server ServiceAccount token when this runs as a Pod (#54), and a developer's own
// kubeconfig otherwise (kubernetes-sandbox-runtime.ts's own header explains the fallback chain).
const app = buildApp(new KubernetesSandboxRuntime(), { logger: true })

try {
    await app.listen({ host, port })
} catch (error) {
    // Fastify's logger, not console: a failure to bind should land in the same stream as every
    // other line this process writes.
    app.log.error(error, 'Sand Castle server failed to start')
    process.exit(1)
}
