<!--
Repository settings that live only in the Macroscope dashboard (Settings → Repos):
- Review Cross-Repo PRs: on
- Correctness: Manual invocation only
- Always Review PR Labels: macroscope-review
Apply the macroscope-review label to request a review on any PR, including one from a fork.
-->

Use Macroscope's default approvability criteria.

Additionally, these pull requests are not auto-approvable and require human review:

- A pull request from a fork, or authored by anyone other than @qeude.
- A pull request that changes a default configuration value or a default shortcut.
- A pull request that adds or broadens use of a private macOS API, or moves one outside `DefiMacOS`.
- A pull request that adds or broadens a directive that disables a lint, type-checker, or
  other diagnostic, or that skips, disables, or removes a test.
