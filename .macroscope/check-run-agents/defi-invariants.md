---
title: Defi Invariants
model: claude-sonnet-5-5
effort: medium
input: incremental
include:
  - "Sources/DefiCore/**"
  - "Sources/DefiRuntime/**"
  - "Sources/DefiMacOS/**"
  - "Sources/DefiDaemon/**"
tools:
  - browse_code
  - git_tools
  - modify_pr
conclusion: neutral
maxBudgetPerRun: 0.5
maxBudgetPerPR: 3
---

# Defi invariants review

Defi's project rules follow. Ignore the Verification, Git, and Agent skills
sections.

@/AGENTS.md

Review only the changed code for a violation of these outcomes:

- A stale asynchronous completion can restore an older focus, frame, layout, or
  visibility state, because nothing checks that a newer intent superseded it.
- A third-party window's position or size changes through anything but public
  Accessibility, or an Accessibility write is issued without comparing it to the
  last written or observed value.
- Accessibility, layout, or capture work can block keyboard capture or command
  intake.
- State is mutated outside `DefiRuntime`, or a platform event reaches state
  without being normalized first.
- An observed frame and a logical target can drive each other in a loop.
- One monitor's windows can be parked in, or leak into, another monitor's visible
  or parking region, or a workspace can belong to two monitors.
- Navigation, focus, or window movement starts to depend on screen capture.

Trace each suspected violation to the code that proves it before you report it.
A pattern that only looks risky is not a finding. Do not repeat what correctness
review covers, such as crashes or ordinary logic errors, and do not comment on
style or naming.

Post each finding as one inline comment: the invariant it breaks, the concrete
sequence that triggers it, and one fix. When there are no findings, make the
entire final response exactly `All clear` on one line with nothing else.
