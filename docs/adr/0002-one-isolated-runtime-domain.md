---
status: accepted
---

# One isolated runtime domain with effects as values

## Context

Defi's window-management state (runtime state, snapshot caches, frame
expectations, corrections) lives on the main actor alongside AppKit,
Accessibility messaging, IPC, timers, and animation driving. Measured
consequences: command queue waits up to 2.7 s when slow applications
(100-500 ms per AX operation) share the main thread with snapshots and
settlement; every new feature adds another contention source. Budgeting and
chunking patches bound individual sections but cannot remove the shared
thread.

The product is young, unreleased, and each phase lands as a revertable
commit, so architectural replacement is affordable now and will not be later.

## Decision

Defi converges on a single isolated runtime domain owning all window-
management state, with platform side effects expressed as values:

1. A dedicated isolation domain (locked engine first, actor at the endgame)
   owns runtime state. All mutations enter it as messages: keyboard commands,
   normalized native events, AX completions, snapshot results.
2. `reduce`-style transitions return state plus effect values ("write this
   frame on the pid-30282 queue", "join the main thread for NSScreen",
   "schedule this timer"). Effect executors route them; completions return as
   new messages.
3. No await ever splits a state transition; message order is the execution
   order.
4. The main thread is demoted to an effect executor: AppKit, NSScreen, event
   taps, observer run loops stay there because macOS requires it, but own no
   state.

The migration is strangler-based, one revertable commit per domain branch:
snapshot caches first (the measured dominant contention), then frame
expectations, then runtime state.

## Consequences

- Determinism becomes structural: two mutations can never interleave.
- Commands, layout, and policies are testable by feeding messages and
  asserting state plus emitted effects - no Accessibility permission, matching
  AGENTS.md.
- The diagnostic journal becomes replayable: same message sequence, same
  execution.
- Latest-wins semantics concentrate in one place instead of scattered
  generation counters.
- The main thread only ever runs microsecond-scale work, so keyboard intake
  stays responsive regardless of application behavior.
- Structural AX latency (slow apps accepting frames late) is unchanged; that
  is a macOS property masked by latency lanes, not a threading property.
- The migration is large and must keep the tree green at every commit; the
  locked-engine intermediate keeps synchronous test compatibility before any
  actor conversion.
