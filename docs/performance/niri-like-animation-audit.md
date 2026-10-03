# Native scrolling animation audit

Updated through 2026-10-02. Scope: the current uncommitted animation implementation,
previous Dia captures, and the public macOS frame backend. The original evidence below precedes the implementation.
The implementation status distinguishes completed fixes from remaining platform limits.

## Target and platform boundary

Preserve the configured spacing throughout horizontal navigation, including
repeated input, reversal, entering/leaving columns, and mouse resizing. Keep
input responsive and prevent stale focus, geometry, and parking restoration.

Niri owns composition. Its transactional updates can retain the old image until
all windows are ready and then present the new image atomically. Defi currently
requests native window geometry individually through Accessibility. A common
submission time does not make native presentation atomic. No reviewed public
API provides a transaction for moving multiple third-party windows together.

Consequently, correcting Defi's scheduling can remove deliberate spacing errors
but cannot guarantee zero transient native spacing error or constant 120 FPS
across arbitrary applications. Those guarantees require control over visual
presentation, not merely faster command processing.

Sources: [Niri transactional updates](https://github.com/niri-wm/niri/releases/tag/v0.1.9),
[Apple Accessibility messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

## Implementation status

Implemented in the public backend:

- Border presentation notifications coalesce across process lanes while the main
  queue is busy. Delivery resolves current geometry only for still-visible
  borders; inactive/removed/suppressed overlays do not trigger native lookups.
  Required intermediate AX fallback, final verification, and parking checks
  remain unchanged. This bounds presentation backlog without advancing ribbon
  progress independently for different applications.

- Intermediate live-border position readback first uses the existing targeted
  public WindowServer geometry query, which validates window ID, PID, layer,
  and finite bounds. Missing metadata falls back to AX. Required immediate
  readback, staging verification, and final verification retain their AX path.
  This removes a measured 21–31 ms AX geometry read from successful 1 ms
  position writes without replacing observed positions with requested ones.

- Position-only horizontal ribbons now retain refresh-rate spring samples and
  use live all-lane readiness for backpressure. Historical AX stalls no longer
  force a later horizontal animation into a sparse sample budget or disable it.
  Vertical transitions and resize retain the conservative latency budget.
  A real stress trace reproduced 42 ms gaps with zero clock lateness: a 125 ms
  animation had been reduced to three samples after an earlier slow Dia write.
  Regression tests cover slow historical predictions, common ribbon progress,
  and unchanged vertical fallback. Actual slow native calls can still lengthen
  a horizontal animation; this does not promise constant presented FPS.

- All eligible ribbon lanes receive the same intermediate and final progression.
  A busy lane holds the next shared sample; unsupported lanes use a coherent
  immediate fallback rather than jumping independently of animated siblings.
- Reentry staging completes before movement starts. Failed staging falls back
  immediately, and supersession is rechecked after the barrier.
- Single-display horizontal samples project logical offscreen origins onto the
  existing one-pixel strip anchors. A targeted public WindowServer read verifies
  staging when immediate AX readback disagrees. Left slivers retain their side.
  Multi-display staging remains conservative until topology-aware projection is
  validated.
- Verified native reentry anchors skip the redundant AX staging write. Queued
  single-display reentries rebase their logical origin with the nearest visible
  neighbor, keeping their relative gap during interrupted navigation.
- After a needed reentry write, matching native bounds bypass delayed AX
  readback and its duplicate position write. Unavailable or mismatched native
  bounds retain the AX verification and retry; final parking remains verified.
- A confirmed Enhanced UI disable is reused across the deferred-restore motion
  sequence instead of rewritten for every sample. Failed disables are retried;
  only the latest restore token can reenable native animation.
- Command intake preserves requested animation timing; execution rechecks the
  shared latency budget so recovery while queued can restore animation. Duration
  zero still performs only final writes, without reentry staging or native bounds
  reads. No animation-specific admission work runs on the intake path.
- Per-process serial queues retain their identity for the daemon session, avoiding
  parallel old/new lanes after temporary discovery loss. Retired native restores
  run on that lane and are included in shutdown draining. Shutdown retries a
  failed native restore once and retains and reports failures instead of forgetting it.
- Offscreen, parking, and size retries recheck the current request immediately
  before each mutation. Supersession stops unnecessary obsolete retries in both
  animated and immediate paths. Standalone Enhanced UI toggles use finite AX
  messaging timeouts; immediate offscreen readback stays inside the frame timeout
  scope, and parking verification uses a finite scope too. Failed retired restores
  remain recoverable at shutdown or rediscovery. Timeout requests bound cooperative AX messaging, not native
  presentation latency; mocked writers cannot validate macOS timeout enforcement.
- The existing per-monitor logical scroll offset is reused. Native point deltas
  are converted to viewport units when rebasing, and the command's monitor is used.
- Successful obsolete native writes update observed starting geometry without
  publishing obsolete final readiness. Failed or skipped motion clears inherited
  velocity, and unchanged intermediate frames avoid AX writes.
- Position-only horizontal movement uses actual intermediate samples, including
  its first animation: a slow parking or final write cannot prevent motion from
  ever being measured. Vertical admission retains conservative general estimates.
- The minimum per-process motion budget now bounds the shared spring sample count
  instead of only toggling animation. Samples are spaced over the configured
  duration and finish with zero terminal velocity. Final settlement starts after
  the last sample completes, without waiting an extra adaptive clock interval.
- Single-display movement uses `NSScreen.displayLink`, with a bounded timer
  fallback for headless, disconnected, multi-display, or stalled-main-loop cases.
  Callbacks enqueue work; they never perform Accessibility operations.
- Display-pulse gating uses the display timestamp and the last accepted pulse,
  rather than callback execution time. Queue jitter cannot suppress the next
  eligible refresh, including the first callback after construction. Coalescing,
  shared-lane backpressure, and timer fallback stay
  bounded; no missed spring samples are consumed as a catch-up jump.
- A busy-lane poll does not consume the display cadence. Only a submitted ribbon
  sample advances the driver's timestamp, so a lane recovering on the next
  refresh does not wait an extra adaptive interval. Polls remain coalesced while
  the callback runs; shared readiness and monotonic spring progression remain.
- A known-window frame refresh reuses unaffected siblings without reading their
  AX attributes or labeling their cached frames as fresh. Topology, unscoped
  events, watchdog/fallback reads, retained windows, and discovery retries retain
  broader refreshes. Coalescing never narrows an earlier unscoped refresh.
  The cache index tolerates duplicate native observations; native focus tests
  exposed this case and a deterministic discovery regression now covers it.
- Deferred command and workspace focus are checked against the current command
  generation before readiness can submit them. Old requests cannot supersede a
  newer monitor command merely because their old frames have become ready.
- Horizontal motion budgets retain measured costs across key pauses up to one
  second, rather than forgetting them after 250 ms without a recovery sample.
  Disabling stalls still expire after 250 ms so final-only fallback cannot
  prevent recovery. Eight consecutive fast samples retire an isolated stall;
  any new slow sample immediately constrains the strip again. Fresh motion
  retires older samples; parking and size work
  never replace horizontal motion measurements.
- Active animation defers nonurgent fresh AX reads at the existing full and
  incremental budget partition and again at preparation/discovery process
  boundaries, so motion starting mid-snapshot also takes priority. Cached
  processes skip fresh transient-owner lookup. Focus/close, resize, uncovered
  observer lanes, and cacheless apps remain urgent; unknown full events bypass
  deferral. The 500 ms age flush remains bounded, including full-refresh chunks.
  Already-running AX calls cannot be interrupted by this scheduling policy.
- Cold horizontal admission can use the measured cost of an already successful,
  ordinary horizontal position-only batch. Parking, reentry, resize, failed,
  and superseded batches cannot seed it. Position setter and timeout costs are
  measured separately from final geometry readback; actual intermediate
  measurements remain authoritative. No probe writes are issued.
- Preparatory AX collection runs on up to four independent process jobs. Reads
  within a process remain serial; queued jobs recheck admission after a completed
  job, and publication restores deterministic order and filters stale results.
  Observer registration and discovery/cache arbitration stay on their owning
  queues. Workers touch frozen handle lists and lock-protected revisions only.
- Timeout reset no longer holds the global AX registry lock. Resetting elements
  remain registered until reset finishes, so a new finite timeout cannot be
  overwritten by an older release; unrelated elements proceed independently.
  Slow-write traces separate registry wait, position setter, other geometry
  work, setup, and reset costs.
- Horizontal motion may defer retained-membership repair only when every
  retained window of the process has a known grace deadline beyond the entire
  500 ms deferral window. Near/unknown deadlines, focus/close, resize, uncovered
  observers, and cacheless processes remain urgent. Vertical/resize/disabled
  motion retain the existing priority. Queued repair remains requested.
- Prepared AX reads use conservative per-process revisions. An unrelated
  process event no longer discards the whole prepared batch; invalidated app
  reads stop before subsequent AX calls and both ends of transient relationships
  must remain valid. New input, unknown scope, session resets, and generic
  invalidations keep a full discard. CG inventory retains its global revision.

Deterministic tests run the real coordinator with injected writes and cover
shared final progression, delayed/failed staging, failed and skipped movement,
obsolete successful completion, and scroll-unit conversion. Native verification
and Computer Use results are recorded separately in `dist/verification/`.

Live-border readback and timeout setup/reset were retained: the historical Dia
trace attributes its long call to position mutation, not meaningful setup/reset
cost. Existing discovery caches and bounded refresh policies are retained until
new profiling demonstrates avoidable contention. Native presentation remains
non-atomic; robust visual edge measurements and private backend validation are
still investigative work, not claimed improvements.

## Evidence

The architecture pass found command planning already isolated from snapshot and
AX execution: the preceding installed trace recorded input-plan p95 of 1.10 ms
while snapshot p95 reached 217.65 ms. Replacing that isolation with another
executor is not supported by these measurements. A read-only native clock probe
observed default display-link intervals near 8.34 ms on the 120 Hz display;
forcing a preferred 120 Hz range did not improve its p95 in the short probe.

Deterministic regressions reproduced skipped refresh pulses after execution
jitter and construction phase at both 60 and 120 Hz, two sibling attribute reads for a one-window frame
refresh, and stale queued focus surviving a newer command generation. The fixes
preserve timer recovery, broader inventory refreshes, and current submitted
focus. Fresh before/after command traces live under
`dist/benchmarks/architecture-before-20260930/` and the corresponding after run.
They measure dispatch and convergence, not presented FPS or atomic visual gaps.

Prepared full-refresh reads still discard all results after newer human input,
and discard the whole affected process after scoped observations. Per-window
reuse is not included: an app-level revision safely covers modal relationships,
window membership, and frame changes without multiplying validity contracts.
Parallel writes within one application's AX handler are also deliberately
avoided because they would weaken mutation ordering without proving presentation
consistency.

- Historical audit: the coordinator chose separate final-dispatch deadlines using each
  process's predicted AX latency. Due processes receive progress 1 while their
  siblings still receive spring progress (`AXFrameCoordinatorAnimation.swift`,
  `finalSubmissionDelayByProcess` and `finalizedProcessIDs`).
- A deterministic scalar replay using the actual functions from
  `Sources/DefiCore/Animation.swift` reproduced a maximum **183.16-point planned
  spacing error** for a 1,000-point translation over 150 ms, with process
  predictions of 2 ms and 40 ms. This is a generated-position inconsistency,
  not a measurement of actual displayed gaps. Output:
  `dist/benchmarks/scheduler-gap-audit-20260930.txt` (ignored, local-only artifact;
  the scalar result is stated here because the output file is not distributed
  with a clean checkout).
- Audited reentry staging was queued before the timer but joined after it finished.
  There is no completion barrier before the first moving sample. An entering
  window can still be staging while another application's windows move.
- Supersession is checked between individual window writes. A partially applied
  old sample can leave adjacent windows at different progress values. Per-window
  completed-position rebasing preserves this actual partial state; replacing it
  with optimistic targets would risk a rollback.
- The previous Dia trace contains a **55.19 ms position operation**, compared
  with an 8.33 ms interval at 120 Hz:
  `dist/benchmarks/dia-run-with-resize-20260929/trace-after.txt` (ignored,
  local-only artifact). This is historical evidence, not a fresh benchmark of
  the latest fixes; the measured value and context are recorded above because
  the trace file is not distributed with a clean checkout.
- The owned-window private probe checks bounds immediately after each call.
  Its inconsistent immediate readback does not distinguish API failure from
  delayed acceptance. It does not establish a usable third-party backend.

## Ranked implementation work

| Priority | Status | Change | Expected benefit and limit |
| --- | --- | --- | --- |
| P0 | Done | Remove per-process early finalization from a horizontal ribbon; submit one shared final progress after its shared intermediate sequence. | Removes the reproduced planned spacing error. AX acceptance remains asynchronous. |
| P0 | Done | Finish successful reentry staging before starting the shared timeline; recheck generation after the barrier. | Prevents siblings from starting ahead of entering columns. Failed staging uses a coherent immediate fallback. |
| P0 | Pending | Model horizontal movement as one offset per monitor/ribbon, using stable logical column geometry. Treat clamped offscreen anchors as presentation bounds, not ordinary logical positions. | Makes constant spacing structural in generated geometry. Must preserve widths, stacked columns, and per-monitor isolation. |
| P0 | Pending | Handle retargeting at a complete shared sample boundary, with latest input replacing the next target rather than letting an old sample stop midway without accounting for partial writes. | Reduces mixed-progress starts. Bound old work; never finish an arbitrarily slow obsolete batch merely to preserve symmetry. Failed or delayed native writes still require reconciliation. |
| P1 | Pending | Retain velocity only for windows whose intermediate position was successfully applied, and clear unsupported velocity on failure. | Prevents inherited motion that never occurred. AX success still does not prove presentation. |
| P1 | Pending | Separate motion latency from final verification/size latency; classify the whole process batch, including window count, with stable recovery. | Reduces unexpected animation/immediate toggling. Existing recent-sample expiry helps, but its fallback prediction still includes non-motion writes. |
| P1 | Pending | Diff intermediate positions against the last accepted/requested intermediate geometry, with correct failure handling. | Avoids repeated subpixel-equivalent AX writes at the spring tail. Final verification, reentry, and parking correctness must not be skipped. |
| P1 | Done | Reuse a per-monitor display-linked clock instead of a free-running timer; callbacks only schedule work and never execute AX. | Improves phase alignment and follows refresh changes. Cannot make slow AX calls meet display deadlines. |
| P1 | Pending | Profile live-border readback and timeout setup/reset on the movement path; move avoidable reads to settlement or the existing bounded observation path. | Reduces AX traffic. Keep accurate border geometry and mandatory offscreen verification; do not delete reads based only on intuition. |
| P2 | Pending | Profile discovery/snapshot contention during movement; defer unrelated inventories while retaining close, focus, display, and user-resize events. | Reduces occasional background interference. Existing caches and bounded refresh policies should be reused. |

For display timing, the code already uses `NSScreen.displayLink` in Overview.
Apple documents its callback as synchronized with that screen's refresh:
[NSScreen display link](https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:)).

The remaining pending items need measurement before implementation. The scalar
model and sample-boundary work are still candidates if repeated navigation
continues to produce incoherent generated geometry.

## Backend decision

First exhaust the coherent public backend. Parallel queues, lower timeouts, and
a display link cannot create atomic presentation. More threads for windows in
one application may simply overload its AX handler and reorder completion.

If measured native skew remains unacceptable, investigate the experimental
frame backend using Defi-owned surfaces only: distinguish call-return latency,
observed convergence, and actual presentation; test several windows, repeated
runs, topology changes, and recovery. A faster single-window move is insufficient.
Require evidence of multi-window consistency before integration. Follow the
repository's dynamic-symbol, session-downgrade, telemetry, and public-fallback
requirements. Third-party mutation remains disabled without explicit opt-in.

A captured visual ribbon could control spacing independently from applications,
but introduces capture freshness, permissions, memory, interaction, and native
handoff problems. It is an alternative product architecture, not a small AX
optimization, and should not be silently added to ordinary navigation.

## Verification that catches the requested defects

Existing convergence tests and `drift=0` are insufficient: a layout can end
correctly after visibly broken intermediate frames. Add a deterministic
scheduler test seam before the P0 changes. It must observe the samples produced
by the actual animation driver, with injected lane delay, staging completion,
write failure, and supersession. Current hard-wired AX writer tests do not
exercise all of those timing interactions without a real desktop.

For each adjacent pair visible in a captured frame, measure:

`spacingError = next.left - current.right - configuredGap`

Positive error is an extra gap; negative error is overlap. Use physical-pixel
rounding tolerance. Detect native window edges independently from scrolling
page content; the current grayscale content correlator is not a reliable
zero-gap acceptance test. Missing/ambiguous observations must be reported,
not counted as passing frames.

Test ordinary single steps, short repeat sequences, held input, reversals,
entering/leaving columns, mixed applications, multiple same-process windows,
mouse resizing during/after motion, and multiple monitors. Compare equivalent
sequences at 60 and 120 Hz and under load. Report maximum and percentile spacing
error, time to first visible movement, presented motion gaps, stale-write
repairs, and final convergence. ScreenCaptureKit can omit unchanged frames;
callback count alone cannot prove displayed FPS.

Preserve and restore the current session under the desktop reservation, verify
native focus using Computer Use, and finish with exactly one daemon. Do not
restore a checkpoint from an earlier day over newer user workspaces.

## Visual ribbon renderer prototype

Explicit user opt-in on 2026-09-30 permits exploring a temporary captured
ribbon. This is an exception to ADR 0001 for this manual rendering experiment,
not a change to the default native-window architecture.

Run `defi toggle-overview --ribbon-prototype` on the installed build. It reuses
the Overview capture cache, screen panel, and display-linked projection at
full-scale zoom. Existing Screen Recording permission is required; the command
does not request a new grant. Left/Right animate the local viewport; Escape
exits without committing its scroll offsets. Window selection, Return, and
drag/drop commits are disabled. Native focus and frames remain unchanged by
prototype navigation. Regular Overview and native animation remain the default.

This proves the rendering/input separation only. Capture resolution and cache
freshness are the existing Overview limits. It does not yet perform automatic
navigation interception or the final handoff to native windows. A production
mode needs a latest-wins handoff that retains the visual surface until the
current native geometry and focus converge, with capability and capture failure
fallback. It must also handle display changes, resize, app closure, and
interaction during the handoff before it can replace normal navigation.


## Native-window review coverage (2026-09-30)

This pass reviews the current implementation, rather than treating every audit
item as an unimplemented feature. It does not establish constant presented
120 FPS or an exhaustive list of all future optimizations.

| Area | Current evidence and decision |
| --- | --- |
| Input and focus | Command intake runs on the navigation domain; native focus writes are asynchronous and latest-wins. Existing no-op, rapid focus, and stale completion checks remain required. No evidence supports another command queue. |
| Timing and retargeting | Display pulses, timer fallback, common progress, completed-position rebasing, and retained velocity already exist. Per-sample Swift allocations are small compared with measured native costs; no speculative rewrite. |
| Ribbon geometry | Shared scalar progression, reentry staging, one-pixel strip anchors, and shared finalization already exist. Independent advancement of fast applications would violate the spacing invariant. |
| Native writes | Different processes run in parallel; each process is serialized. Additional threads inside one application do not establish ordering or atomic presentation. Real native position calls still exceeded 50 ms in the baseline. |
| Native reads | Public WindowServer metadata precedes intermediate AX fallback. The installed baseline reports private bounds unavailable, so deleting the public fallback would remove observed border tracking. Keep mandatory final, staging, resize, and parking verification. |
| Presentation backlog | Implemented notification coalescing and visible-border filtering. Queued work carries IDs and resolves current geometry at delivery, preserving native resize and latest selection. |
| Discovery and contention | Fresh reads already have process budgeting, bounded deferral, caching, chunking, and parallel prepared reads. Lifecycle, close, focus, and user-resize observations cannot be dropped to improve an animation benchmark. |
| Load adaptation | Horizontal motion uses live readiness; vertical/resize retains coherent fallback. A shared gate prevents independent lanes from creating additional spacing errors, but cannot hide a genuine slow native write. |
| Verification | Stress now waits for three settled, drift-free samples and requires final command-animation cadence. It excludes unrelated generations and samples with no applied intermediate writes. Dispatch remains distinct from presented frames and edge spacing. Hardware-dependent 60 Hz and multi-display coverage must be reported separately. |
| Alternative backend | The owned-surface private mutation probe was not repeatably correct. Third-party mutation is not authorized by this pass and remains disabled. The manual captured prototype does not satisfy native interaction requirements. |

Baseline: `python3 script/ribbon_stress.py --workspace web --steps 16`
failed the 25 ms dispatch budget at **25.26 ms**, with successful session
restoration (`dist/benchmarks/ribbon-stress-1790783358981374000`). Its final
animation took about 281 ms for a configured 125 ms spring. Slow native position
calls reached 54.71 ms; one geometry operation reached 19.50 ms. These are
scheduler/native-call observations, not presented-frame measurements. The
fixed 400 ms tail in that older harness was a measurement weakness, now removed.

Slow-write diagnostics now identify `phase=motion`, `phase=staging`, or
`phase=final` so a final verification stall is not incorrectly presented as a
per-frame motion read. Further changes to readback require this attribution and
an actual native-window comparison. The current capture correlation estimates
motion approximately; it does not prove absence of transient gaps or overlaps.

## Rebased clock investigation (2026-10-02)

Rebased onto `origin/main` (`f89d0f1`); this repository has no `origin/master`.
Upstream native height constraints, fresh constraint lookup after mouse release,
and preservation of windows with temporarily unavailable AX roles are retained.

An animation-enabled 16-command baseline on the web workspace exceeded the
25 ms dispatch budget at **25.17 ms**
(`dist/benchmarks/ribbon-stress-1790958254107846000`). Aggregate clock diagnostics
now distinguish delivered display pulses, fallback steps, busy-lane pulses, and
maximum intermediate lane latency. They exposed both missing display callbacks
(a 25.01 ms gap without busy lanes) and intermediate geometry reads taking
14.99–18.59 ms. These are separate bottlenecks.

The fallback previously waited for two intervals after *any* display callback,
including callbacks that were coalesced or could not advance a sample. A
deterministic alternating-callback test reproduced half the intended cadence at
both 60 and 120 Hz. Fallback now measures time since the last sample actually
executed; display pulses retain timestamp-based cadence. Queued work is still
coalesced, busy lanes do not consume progress, and old display timestamps cannot
replay a fallback step. Tests also cover a late display callback immediately
followed by a timer pulse, so stale timestamps cannot produce a catch-up burst.

The live-border geometry read remains synchronous pending a safe, measured
replacement. Removing it would promote an optimistic target to observed border
geometry. Final, resize, staging, and parking verification remain required.
The user's disabled-animation setting is restored after each animated stress
run. These checks do not establish constant presented 120 FPS.

### Follow-up with Xcode and more windows

The user subsequently enabled animations. The 16-command `dev` workspace
baseline exceeded the dispatch budget at **33.44 ms**
(`dist/benchmarks/ribbon-stress-1790961459372563000`). Xcode's position write
took 1.48 ms followed by 24.39 ms of geometry work in one intermediate sample.
Separate width-change traces also contain expensive size work; the geometry
timing bucket must not be interpreted as read-only cost for resize commands.

An owned-panel probe reproduced a startup capability bug: an allocated panel
returned a successful bounds lookup with a zero rectangle before AppKit committed
its frame. The previous provider disabled bounds metadata permanently for that
result. A valid 64-by-64 surface succeeded; read-only lookups for the current
Xcode window IDs matched public WindowServer geometry. These probe results do
not authorize or use private window mutation.

The capability probe now waits for nonempty owned geometry and selects only
initialized border segments. Frame lanes reuse that existing optional bounds
provider for intermediate/staging position reads. Mutable bounds state is
protected by a mutex, while constraint queries remain on the main actor and
cannot hold that mutex. Failed or unavailable private reads immediately fall
back to the existing public WindowServer and Accessibility path. Regression
tests cover deferred probe readiness, session downgrade after real failure,
and concurrent readers. Mandatory final, resize, and parking verification is
unchanged; no application-specific exception is introduced.

### Independent border observation and immediate-mode parity

A follow-up trace still showed 28.94 ms in the geometry portion of an
intermediate Xcode sample, against 4.24 ms for its position write. Presentation
already samples that border's native bounds independently. Horizontal,
position-only intermediate writes now omit their duplicate border read while
that independent provider is available. Staging, parking, size changes, final
acceptance and the zero-duration path keep their readbacks. Provider downgrade
restores the existing synchronous public/AX fallback on the next sample.

A successful position command still updates motion bookkeeping and invalidates
older observations, but no longer becomes observed border geometry on this
path. Presentation records its timestamped native sample instead. Tests cover
both capability states and reject an observation started before the write.

The comparison against origin/main f89d0f1 also found a shared layout delta:
left-edge overlaps of at most one point used a different parking anchor even
with animations disabled. Exit-side preservation is now explicit and enabled
only for animated layouts/projection. The default immediate layout retains
main's parking boundary, covered at zero, fractional, one-point and visible
overlaps. Zero-duration writes are tested with independent observation both
available and unavailable. These checks do not establish constant presented
120 FPS or equivalence for every possible desktop interaction.

A separate trace showed ~9 ms process lanes waiting for the next ~16.7 ms timer
pulse after narrowly missing an 8.3 ms refresh. Draining a lane now requests a
cadence-guarded clock retry after releasing that lane's readiness. All lanes
must still be ready, each accepted tick advances exactly one sample, and a
completion cannot start a sample before a full interval has elapsed. Display
and timer pulses remain the fallback for coalesced notifications; stopped or
superseded drivers cannot revive an older animation. Zero-duration writes never
create this driver. Tests cover readiness ordering, 60/120 Hz timing, early
completion rejection and stopped-driver rejection.

### Completion arriving during a busy tick

A deterministic driver test exposed a lost wake: the final AX lane could finish
after a tick found it busy but before the clock cleared its queued flag. The
completion now survives that interval and retries once after the unsuccessful
tick. An accepted sample consumes the notification without accelerating the
cadence; stopping the driver also discards it. The test disables timer/display
fallback so neither can hide this race.

Temporary instrumentation separated individual AX setters from the surrounding
write/verification cost. Two 32-command Dia runs recorded 70 slow intermediate
writes, all single attempts; one successful setter alone took 48.46 ms. There
was no redundant retry to remove in these samples. Display-link attachment
medians were 7.23 and 4.06 ms, first-pulse medians 15.41 and 9.82 ms; timer/lane
fallback remained active. This does not demonstrate a gain from shared-link
lifecycle. The probes were removed after measurement. Only the reproducible
completion race is changed; final/disabled-mode writes remain untouched.

### Discovery-read contention experiment

Temporary probes observed a 256 ms Dia discovery batch overlapping its native
movement lane. This measures the whole discovery batch, not time spent only in
AX or proof that the reads caused the write latency. No additional actor or
within-process write concurrency was introduced.

Two per-window admission experiments reused the existing bounded process-read
policy: first for cached inventories, then also for known windows in refreshed
inventories while preserving new/missing-window discovery, retention and owner
resolution. Both passed focused regression and native tests, but neither yielded
a window read in its 32-command Dia stress run. Maximum dispatch gaps were
24.13 and 31.57 ms, versus 53.02 ms before instrumentation and 29.70 ms with only
the probes. This variation does not establish a performance improvement; neither
candidate met the 16.7 ms stress budget, and dispatch gaps are not presented FPS.

Both candidates and their temporary probes/tests were removed. The existing
animation and non-animation paths are unchanged by this experiment. The precise
admission reason for the overlapping reads remains unproven; suppressing critical
discovery or native focus without that evidence would risk correctness.

### Focus echoes and shared adaptive cadence experiment

No production change was retained from this experiment. The temporary focus
probe and the adaptive cadence candidate were removed; the previously verified
build was restored. Existing unrelated work was preserved.

The focus probe found that most internally generated focus echoes in the Dia
sequence coincided with geometry reconciliation. Those reads cannot safely be
removed as focus-only metadata work. Its `reads` counter measured fallback
attribute calls only, not batched AX reads; zero did not mean zero AX cost.

The cadence candidate reused recent per-process motion samples, tagging only
horizontal position-only command animation writes. Three or more fresh samples
with a median above the display budget selected half the display rate for the
entire next animation. A single outlier, resize/final cost, or cold lane did not
lower cadence. A failing-then-passing integration test verified shared,
monotonic progress for two process lanes. No independent lane progress or
wall-clock sample skipping was introduced.

The controlled comparison did not establish a useful net improvement:

| Sequence on web | Previous build | Adaptive candidate |
| --- | ---: | ---: |
| 16 commands, 180 ms interval: maximum dispatch gap | 64.37 ms | 71.86 ms |
| Same sequence: median animation completion | 162.64 ms | 160.30 ms |
| 32 commands, 60 ms interval: maximum dispatch gap | 17.55 ms | 25.60 ms |
| Same burst: median generation completion | 75.30 ms | 75.46 ms |

These are single-run observations, not causal proof of a regression. Burst
completion includes superseded generations. Dispatch gaps are not presented
FPS. The candidate selected 60 Hz for five ordinary and four burst generations,
but both builds exceeded the 16.7 ms dispatch budget. This evidence does not
justify keeping the extra policy. Artifacts and the rejected patch are under
`dist/benchmarks/cadence-comparison-1790972763071608000/`.

An earlier comparison was discarded because its temporary harness checkpointed
immediately after installation, before daemon discovery (`workspace=none`,
`focused=none`). Persisted topology was restored exactly, but the impossible
startup focus made the checker fail. The harness was corrected to await the
existing `desktop_session.start()` readiness check; every subsequent comparison
restored the session successfully.

Candidate verification passed 979 Swift tests, 12 workflow tests and seven
focused native tests, with Accessibility available. The animation-disabled A/B
against `origin/main` (`f89d0f1`) passed ten commands across 21 windows on one
monitor, including focus, width and workspace changes, native-frame comparison,
and flushed final topology. No animated submission occurred. Original config
bytes and exactly one daemon were restored. Artifact:
`dist/benchmarks/immediate-parity-1790972693581130000/result.json`.
The rejected cadence code was entirely outside that immediate execution path.

Computer Use inspected Xcode after navigation and attempted a title-bar click;
logical focus remained on its neighbor, so this does not establish successful
native focus transfer. Short CLI navigation settled with zero drift and the
initial workspace was restored. The available app-bound screenshots cannot
establish whole-ribbon edge spacing or continuous 120 Hz presentation. No claim
of globally glitch-free animation or constant 120 FPS follows from these checks.

After removing the experiment, `verify.py local` passed again (978 Swift tests
and 12 workflow tests; `dist/verification/20261002-222822-0866f4cf`). The installed
binary matches the previously verified baseline bundle. Final checks confirmed
byte-identical config, checkpoint-identical monitor topology and logical focus,
zero drift and one daemon. No new production optimization remains from this pass.

## Motion priority experiment (2026-10-02)

Retained one change: intermediate horizontal, position-only command-animation
lane drains explicitly use Dispatch `.userInteractive` with `.enforceQoS`.
The existing clock queue's priority did not propagate to the per-process
`.userInitiated` queue: a test through the actual submission path observed QoS
25 before the change and 33 afterward. Final submissions still observe QoS 25;
immediate, staging, resize, and vertical paths keep their previous scheduling.
No new queue, actor, AX call, configuration, or frame ordering was introduced.

A clean baseline/candidate/candidate/baseline comparison used the same saved
session, with two repetitions of each case per build. Web used 16 commands at
180 ms and 32 commands at 60 ms; dev used 16 commands at 180 ms. The following
values are medians of the two runs' median per-animation maximum dispatch gaps:

| Case | Existing priority | Motion priority |
| --- | ---: | ---: |
| Web, ordinary timing | 18.37 ms | 18.52 ms |
| Web, rapid navigation | 14.36 ms | 12.26 ms |
| Dev, including Xcode | 14.42 ms | 10.43 ms |

Median completion summaries were 173.87/167.41 ms, 83.68/83.16 ms, and
143.60/136.60 ms respectively (baseline/candidate). Rapid navigation includes
superseded generations. Ordinary web cadence did not improve; dev and rapid web
showed smaller gaps in both candidate runs. The largest candidate gaps still
reached 51.51 ms. These are scheduler and AX submission measurements, not
presented-frame FPS, and do not establish continuous 120 Hz. All twelve session
restorations passed. Artifact:
`dist/benchmarks/animation-candidate-comparison-1790975959223873000/results.json`.

A separate persistent per-monitor display-link experiment successfully reused
and paused links, but its repeated comparison did not demonstrate a net latency
or cadence benefit, especially on dev. It was removed, including its tests and
extra diagnostics. Artifact:
`dist/benchmarks/animation-candidate-comparison-1790974110493537000/results.json`.
Temporary AX overlap probes were also removed. Four candidate motion samples
around 50–52 ms overlapped unclassified AX activity on the same cached handles;
none carried the tagged focus, inventory, or focus-resolution bits. The owner is
not yet attributed. Changing timeout arbitration or serializing application
traffic without that evidence could harm focus and lifecycle responsiveness, so
neither was introduced. Probe artifact:
`dist/benchmarks/animation-candidate-comparison-1790975829915105000/results.json`.

Verification passed 979 Swift tests and 12 workflow tests
(`dist/verification/20261002-231531-7b89b33d`), followed by seven focused native
tests with Accessibility available and complete session restoration
(`dist/verification/20261002-232106-7f4c997f`). The animation-disabled comparison
against `origin/main` (`f89d0f1`) found no differences across ten focus, width,
and workspace commands and twenty managed windows on one monitor. Native frames
were compared within one point, final persisted topology matched, and no
animated submission occurred. Config bytes and one daemon were restored.
Artifact: `dist/benchmarks/immediate-parity-1790976096154655000/result.json`.

Computer Use navigated to Xcode with ordinary timing, inspected its app-bound
screenshot and source-editor accessibility state, and performed a normal title
click. Logical focus stayed on Xcode after the click. An injected shortcut was
not observed by Defi's event tap, so it is excluded from native hotkey validation.
App-bound inspection does not prove whole-ribbon spacing or continuous
presentation. Initial workspace, logical focus, widths, scroll, and managed
frames were restored; config bytes and the installed prepared binary matched,
and exactly one daemon remained. Artifact:
`dist/benchmarks/qos-computer-use-1790976160565504000/result.json`.


## PR review verification (2026-10-03)

Review fixes preserve the 125 ms default and public Accessibility fallback.
They cover stale native focus, no-op focus intent, accepted border observations,
scoped snapshot invalidation, reentry staging, delayed display pulses, and
benchmark restoration. Process queue retirement waits for queued, delayed,
and animation work; overview requests track pending intent independently of
the asynchronously published UI state.

A comparison against the original PR commit (`3bd2947`) used the same saved
session and 125 ms configuration on one monitor. Each build ran 16 navigation
steps at 180 ms spacing and 32 at 60 ms spacing in both web and dev workspaces.
The largest motion-dispatch gaps in each run were:

| Workspace / timing | Original PR | Review candidate |
| --- | ---: | ---: |
| Web / ordinary | 16.59 ms | 17.20 ms |
| Web / rapid | 14.55 ms | 17.06 ms |
| Dev / ordinary | 14.85 ms | 14.60 ms |
| Dev / rapid | 13.74 ms | 15.00 ms |

The candidate here is `b9dc3a5`, before the final queue-retirement and overview
fixes. These are dispatch measurements rather than presented-frame FPS. The
small mixed changes do not demonstrate a speedup or sustained 120 Hz. Each
comparison restored workspace topology, logical focus, widths, scroll, and
managed frames. Local-only artifacts are under
`dist/benchmarks/pr118-review/`.

The animation-disabled comparison against `origin/main` (`f89d0f1`) deliberately
did not reach exact parity: after a right command at the ribbon boundary,
baseline native focus reverted from 72245 to 65242 despite a preserved logical
selection of 72245. The candidate retained the intended focus; native frames
matched at that no-op. Later width differences follow the different focused
window. This is evidence for the no-op focus fix, not a geometry parity pass.
Configuration bytes and the saved desktop session were restored, with exactly
one daemon. Artifact:
`dist/benchmarks/immediate-parity-1791019452101045000/result.json`.

The complete native run at `bacf0be` passed 30 tests with Accessibility available
and skipped six: five require a second display, and reentry requires two
eligible native windows on one monitor. Session restoration passed. The focused
reentry retry at `b9dc3a5` also skipped for fixture availability. These skipped
cases remain unverified on this desktop; the verification runner correctly
reports the runs as incomplete rather than fully passed.
