// The sandbox runtime boundary (docs/ARCHITECTURE.md §18).
//
// §18 says to "define a generic runtime boundary early" so that DockerRuntime, LocalRuntime,
// FirecrackerRuntime and RemoteSandboxRuntime become possible "without redesigning the Run
// model" -- naming KubernetesSandboxRuntime (#52, #53) as the only implementation it expects
// for now. The usual bar for a new interface is a real second implementation or a real test
// seam, never principle alone; this is the documented exception, by name, and it applies to the
// five methods below and nothing past them. It is not licence to add further abstraction here.
//
// Two deviations from §18's literal pseudocode:
//   - Every method returns a Promise. §18 writes synchronous-looking signatures, but the only
//     implementation these will ever have talks to the Kubernetes API over the network, so a
//     synchronous signature would misdescribe every real caller.
//   - §18 writes `run` as the argument to all five methods. The Run entity is Phase 4 (§38) and
//     does not exist yet, so `create` takes a minimal SandboxCreateInput instead, and the other
//     four take the SandboxHandle `create` returned -- the runtime's own reference to what it
//     made, which is all they need to act on it.

/**
 * What a sandbox needs to be created. Shaped like §37's `POST /api/test-runs` body, not the
 * `runs` table (§7) -- that table is Phase 4 persistence for a Run entity that doesn't exist
 * yet, and this describes a request to create a sandbox, not a persisted run. Whatever identity
 * the runtime needs internally (a Job name, a Pod name, ...) is its own concern; callers learn
 * it from the returned SandboxHandle.
 */
export interface SandboxCreateInput {
    repository: string
    issue: number
    // String union, not a type imported from an agent module that doesn't exist yet: §27 names
    // exactly these two, and images/agent/bootstrap/sandcastle-run validates the same pair.
    agent: 'claude' | 'codex'
}

/** The runtime's own reference to a sandbox it created, passed back into every other method. */
export interface SandboxHandle {
    sandboxId: string
}

/**
 * A sandbox's own status -- narrower than §8's Run state machine, which is application-level and
 * belongs to the Run, not the sandbox (queued and preparing happen before a sandbox exists;
 * completing, cancelled and timed_out are Sand Castle's reaction to one, not the sandbox's own
 * state). `phase` is the subset §38 already names as what the Phase 4 UI shows for a running
 * sandbox. `exitCode` follows from §19's stated benefit of a Job: "well-defined exit status".
 */
export type SandboxPhase = 'creating' | 'starting' | 'running' | 'completed' | 'failed'

export interface SandboxStatus {
    phase: SandboxPhase
    exitCode?: number
}

/**
 * §18's runtime boundary. `create` is the only method Phase 3 exercises (§37); `get`, `stop`,
 * `logs` and `cleanup` are declared because §18 names them, with no semantics invented beyond
 * what §18 and §8 already imply -- in particular, `logs` returns the log text collected so far,
 * not a stream, since nothing so far asks for one (§32's real-time UI is a later concern).
 */
export interface SandboxRuntime {
    create(input: SandboxCreateInput): Promise<SandboxHandle>
    get(handle: SandboxHandle): Promise<SandboxStatus>
    stop(handle: SandboxHandle): Promise<void>
    logs(handle: SandboxHandle): Promise<string>
    cleanup(handle: SandboxHandle): Promise<void>
}
