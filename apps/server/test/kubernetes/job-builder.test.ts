// The Job builder, checked against the renderer it has to agree with.
//
// The first test is the reason this file exists. src/kubernetes/job-builder.ts and
// deploy/kubernetes/scripts/render-job.sh both produce the agent Job, and #26 is what two
// producers of one artifact cost when nothing compares them. So this does not compare against a
// fixture written by reading the bash -- a fixture would only prove its author read the script
// the same way twice, which is the failure #28 documents. It runs render-job.sh, parses what it
// actually printed, and requires it to equal the object the builder returns, field for field.
// Change either side alone -- the image digest, a resource limit, an env var, the namespace --
// and this goes red.
//
// No credential appears anywhere below, and none can: the manifest carries secret *references*,
// and the only Secret names here are the ones create-secrets.sh creates (§14, §52, §57).

import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { test } from 'node:test'
import { parse } from 'yaml'
import { buildAgentJob, type AgentJobInput } from '../../src/kubernetes/job-builder.ts'

const RENDER_JOB = path.join(
    import.meta.dirname,
    '../../../..',
    'deploy/kubernetes/scripts/render-job.sh',
)

/** One well-formed, meaningless run, as validate.sh keeps its own sample. */
const SAMPLE: AgentJobInput = {
    runId: 'run-042',
    repository: 'octocat/Hello-World',
    issue: 7,
    agent: 'claude',
}

/** What render-job.sh printed for these inputs, as data. */
function render(input: AgentJobInput): unknown {
    const yaml = execFileSync(RENDER_JOB, [input.runId, input.repository, String(input.issue)], {
        encoding: 'utf8',
    })

    return parse(yaml)
}

test('the builder produces what render-job.sh produces for the same run', () => {
    assert.deepEqual(buildAgentJob(SAMPLE), render(SAMPLE))
})

// A run ID that is a valid DNS-1123 label and also reads as a YAML integer, which is why job.yaml
// quotes every placeholder and validate.sh renders a second time with this one. The builder has
// no quoting to get wrong, but it does have `String(issue)` and a run ID it copies into a label
// -- and this is what proves the two sides still agree once YAML's scalar rules are in play,
// rather than agreeing only for inputs that cannot expose them.
test('the builder and render-job.sh agree on a run ID that reads as a number', () => {
    const input: AgentJobInput = { ...SAMPLE, runId: '0755', issue: 1 }

    const built = buildAgentJob(input)

    assert.deepEqual(built, render(input))
    assert.equal(built.metadata.labels['sandcastle.run'], '0755')
    assert.equal(built.spec.template.spec.containers[0]?.env[0]?.value, '0755')
})

// §20 and #18: the rule validate.sh holds the manifests to, applied to the copy of the reference
// that lives in TypeScript. Replace the digest with `:latest`, or with a commit-SHA tag, and this
// fails -- as does the equivalence test above, since job.yaml still pins the digest.
test('the agent image is pinned by digest, not by a mutable tag', () => {
    const image = buildAgentJob(SAMPLE).spec.template.spec.containers[0]?.image

    assert.match(
        image ?? '',
        /^ghcr\.io\/pmhood\/sandcastle-agent@sha256:[0-9a-f]{64}$/,
        `the agent image must be a digest, and is '${image ?? '(missing)'}'`,
    )
})

// The #14 rule as it applies to what the server hands Kubernetes: a credential is either a
// reference that resolves or the Pod does not start. `optional: true` and a literal `value` are
// the two ways an unset credential becomes an empty one instead.
test('every credential arrives by Secret reference, with no value in the manifest', () => {
    const env = buildAgentJob(SAMPLE).spec.template.spec.containers[0]?.env ?? []
    const byReference: string[] = []

    for (const entry of env) {
        if (entry.valueFrom) {
            byReference.push(entry.name)
            assert.equal(entry.value, undefined, `${entry.name} carries a literal value as well`)
            assert.equal(
                'optional' in entry.valueFrom.secretKeyRef,
                false,
                `${entry.name} is optional, so a missing key becomes an empty value`,
            )
            continue
        }
        // The plain-value side, held to the pattern validate.sh matches, so that one rule covers
        // both renderers: nothing that reads as a credential may be written in as a value.
        assert.doesNotMatch(
            entry.name,
            /TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|OAUTH/,
            `${entry.name} is written in as a literal value`,
        )
        assert.notEqual(entry.value, '', `${entry.name} is an empty literal value`)
    }

    assert.deepEqual(byReference.sort((a, b) => a.localeCompare(b)), [
        'CLAUDE_CODE_OAUTH_TOKEN',
        'GITHUB_TOKEN',
    ])
})

// render-job.sh refuses each of these rather than substituting it; so does the builder, with the
// same shapes, so a run the command line rejects is a run the server rejects too.
test('an input the manifest cannot carry is refused', () => {
    assert.throws(() => buildAgentJob({ ...SAMPLE, runId: '' }), /not a DNS-1123 label/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, runId: 'Run-042' }), /not a DNS-1123 label/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, runId: '-run' }), /not a DNS-1123 label/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, runId: 'r'.repeat(53) }), /longer than 52/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, repository: 'Hello-World' }), /not owner\/repo/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, repository: '' }), /not owner\/repo/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, issue: 0 }), /not a positive integer/)
    assert.throws(() => buildAgentJob({ ...SAMPLE, issue: 1.5 }), /not a positive integer/)
})

// The one input render-job.sh does not take, because job.yaml sets AGENT as a constant: the agent
// and its credential change together, and there is no Codex Secret for create-secrets.sh to have
// created. A Codex Job would start and then fail to authenticate.
test('an agent with no credential Secret is refused rather than half-rendered', () => {
    assert.throws(
        () => buildAgentJob({ ...SAMPLE, agent: 'codex' }),
        /agent 'codex' has no credential Secret/,
    )
})
