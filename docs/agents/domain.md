# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/internals/`** — read the pages that touch the area you're about to work in.

If any of these files don't exist, proceed silently. The `/domain-modeling` skill creates them lazily when terms or decisions are resolved; record decisions in `docs/internals/`, not as numbered ADRs.

## File structure

Single-context repo:

/
├── CONTEXT.md
├── docs/internals/
└── Sources/

## Use the glossary's vocabulary

When output names a domain concept, use the term as defined in `CONTEXT.md`. If the concept is not in the glossary yet, reconsider the terminology or note the gap for `/domain-modeling`.

## Flag internal-doc conflicts

If output contradicts a page in `docs/internals/`, surface it explicitly rather than silently overriding it. When the change is intended, rewrite that page in the same change.
