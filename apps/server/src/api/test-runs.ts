// POST /api/test-runs (docs/ARCHITECTURE.md §37) -- the endpoint Phase 3 is actually about: a
// request comes in, this validates it, src/kubernetes/job-builder.ts (#52) renders a Job, and
// the SandboxRuntime (#51, #53) submits it. This is stateless, on purpose (§38 is Phase 4's:
// persisting the Run, watching it, streaming its logs -- none of that exists yet).
//
// ## Why this name, and why it is temporary
//
// §37 names this route `/api/test-runs`; §33's Initial API has no such route -- it lists
// `GET /api/runs`, `GET /api/runs/:id`, `POST /api/runs/:id/stop` and so on. `test-runs` reads
// as Phase 3 scaffolding, and it is: a run this server creates but cannot yet be looked up,
// stopped, or streamed, because the Run persistence §33's shape implies is §38's, not this
// issue's. Naming the route `/api/runs` today would promise those verbs before they exist;
// keeping §37's name says plainly that this is what Phase 3 builds, not the finished API.
//
// This is written down in two places so the name does not quietly become permanent: here, and
// in apps/server/README.md's section on this endpoint. Whichever issue implements §38 (Run
// persistence) is the one that moves this to `/api/runs` -- and deletes this comment.
//
// ## Validation, and why it happens here rather than only in job-builder.ts
//
// `buildAgentJob` (src/kubernetes/job-builder.ts) already validates `repository`, `issue` and
// the run ID it mints -- but that is the last line of defence, not the first. A request that
// fails there would surface as a 500 out of manifest rendering, deep inside `create()`, which
// tells a caller "something broke" instead of "you sent something wrong". The schema below is
// what makes a malformed request a 400 at the door instead.
//
// `repository` reuses job-builder.ts's own REPOSITORY_PATTERN -- one pattern, not a second copy
// that could drift the way #26 was filed over. It rejects a shell metacharacter (`;`, ` `,
// backtick, ...) and a path-traversal-shaped value outright: the character class allows no `/`
// beyond the one separating owner from repo, so `../../etc/passwd` (three slashes) cannot match
// even though `.` and `-` are otherwise permitted characters.
//
// `issue` is a JSON-Schema `integer`, which already rejects a string, a float, and (with
// `minimum`) a negative value. `maximum` is this file's own addition on top of job-builder.ts's
// check: mathematically an integer has no upper bound, but a real GitHub issue number does, and
// a request naming issue 10^21 is not a legitimate one that got unlucky -- it is hostile input
// worth refusing outright rather than stringifying into a Job's environment. MAX_ISSUE_NUMBER is
// comfortably past any real repository's issue count.
//
// `agent` accepts only `'claude'`, not `SandboxCreateInput`'s full `'claude' | 'codex'` union.
// job-builder.ts's own validateInput already rejects `'codex'` for the same reason stated there:
// deploy/kubernetes/scripts/create-secrets.sh provisions a Claude OAuth Secret and no Codex one,
// so a Codex Job would start and fail to authenticate (#52's finding). Rejecting it here, before
// the request reaches the runtime, makes that the same decision one layer earlier -- a 400
// instead of a rendering failure -- and keeps this file's schema and job-builder.ts's checks in
// agreement for every field a client controls, so `create()` never throws over a body this
// schema already accepted (see kubernetes-sandbox-runtime.test.ts for what a mismatch there
// would look like: an unclassified Error, not one of the four below, falling through to 500).
//
// Fastify's default AJV instance coerces types and silently drops unknown properties
// (`coerceTypes`, `removeAdditional`, `useDefaults`), which would defeat both of the checks
// above: a numeric string would pass an `integer` check, and an unexpected field -- an OAuth
// token, say -- would be stripped and the request accepted rather than refused. src/app.ts turns
// all three off, which is what makes `additionalProperties: false` below reject a request with
// an extra field (400) rather than silently accept it with the field quietly removed. Either
// way, this handler builds the SandboxCreateInput it passes to the runtime field by field, not
// by forwarding `request.body` -- so even a schema this file got wrong could not make an
// unexpected field reach the runtime, get rendered into the Job, or be echoed back (§52, §57).
//
// ## Status codes
//
// - 201, with the created sandbox's ID: the Job now exists.
// - 400: the client sent something malformed -- the schema below rejected it, or Fastify could
//   not parse the body as JSON at all.
// - 502: the request was well-formed but the Kubernetes API refused to create the Job -- an RBAC
//   denial, a missing namespace, or any other rejection `KubernetesSandboxRuntime.create`
//   classifies (kubernetes-sandbox-runtime.ts). Sand Castle reached the cluster and the cluster
//   said no, which is what 502 (Bad Gateway) means for an upstream that answered with a
//   rejection.
// - 503: the call never reached the API server at all (connection refused, DNS failure, a
//   malformed kubeconfig). The cluster is not refusing, it is unreachable, and a retry later may
//   succeed -- 503 (Service Unavailable) is that distinction from 502.
// - 500: anything else -- a bug here or in a dependency, not a response the cluster classified.
//
// The full detail behind a 502 or 503 -- the namespace, which RBAC manifest to check, the
// Kubernetes API's own reason and message -- is exactly what an operator needs from a log and
// exactly what a caller of this HTTP endpoint has no business learning: it names internal
// manifests and namespaces. That detail goes to `request.log.error`; the response carries only
// which of the two classes it was, in a fixed, static message with nothing from the underlying
// error interpolated into it -- so there is nothing in the response for a credential, a
// namespace, or a stack trace to leak through, regardless of what the classified error's own
// message says.

import type { FastifyInstance } from 'fastify'
import { REPOSITORY_PATTERN } from '../kubernetes/job-builder.ts'
import {
    ApiRejectionError,
    ClusterUnreachableError,
    NamespaceMissingError,
    RbacDeniedError,
} from '../kubernetes/kubernetes-sandbox-runtime.ts'
import type { SandboxCreateInput, SandboxRuntime } from '../sandbox/runtime.ts'

// See the file header's "Validation" section for why this exists and where the number comes
// from.
const MAX_ISSUE_NUMBER = 100_000_000

interface CreateTestRunBody {
    repository: string
    issue: number
    agent: 'claude'
}

const bodySchema = {
    type: 'object',
    additionalProperties: false,
    required: ['repository', 'issue', 'agent'],
    properties: {
        repository: { type: 'string', pattern: REPOSITORY_PATTERN.source },
        issue: { type: 'integer', minimum: 1, maximum: MAX_ISSUE_NUMBER },
        agent: { type: 'string', enum: ['claude'] },
    },
} as const

export function registerTestRunsRoute(app: FastifyInstance, runtime: SandboxRuntime): void {
    app.post<{ Body: CreateTestRunBody }>(
        '/api/test-runs',
        { schema: { body: bodySchema } },
        async (request, reply) => {
            // Built field by field, not `{ ...request.body }` -- see the file header's
            // "Validation" section for why that matters even though the schema above should
            // already guarantee there is nothing else on request.body to forward.
            const input: SandboxCreateInput = {
                repository: request.body.repository,
                issue: request.body.issue,
                agent: request.body.agent,
            }

            try {
                const handle = await runtime.create(input)
                reply.code(201)
                return { sandboxId: handle.sandboxId }
            } catch (error) {
                if (
                    error instanceof RbacDeniedError ||
                    error instanceof NamespaceMissingError ||
                    error instanceof ApiRejectionError
                ) {
                    request.log.error(error, 'the Kubernetes API rejected the Job for this run')
                    reply.code(502)
                    return { error: 'the Kubernetes cluster rejected the request' }
                }
                if (error instanceof ClusterUnreachableError) {
                    request.log.error(error, 'could not reach the Kubernetes API to create the Job')
                    reply.code(503)
                    return { error: 'the Kubernetes cluster is unreachable' }
                }
                // Not one of the four classified errors classifyFailure throws: an unexpected
                // bug, not a cluster response. Rethrown so Fastify's default error handler
                // answers 500, rather than folding it into one of the classes above and telling
                // a caller something specific that is not actually true.
                throw error
            }
        },
    )
}
