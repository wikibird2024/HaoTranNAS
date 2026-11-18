# HaoTranNAS — project rules for Claude

One-repo learning project: phone/PC backup to a self-built server on a home NAS.

## Read before working

| When | Read |
|---|---|
| Any design question | `docs/architecture.md`, `docs/decisions.md` |
| Picking the next task | `docs/roadmap.md` (current milestone and its "Done when") |
| Writing code or adding files | `docs/conventions.md` (folder ownership, dependency rules, naming) |

## Project facts

- Sub-projects: `protocol core server cli desktop mobile nas e2e`; system docs live only in root `docs/`.
- `protocol/*.proto` is the single source of truth for the wire format. Change it first.
- Casing follows each language: Rust and proto `snake_case`, Kotlin `camelCase`, types `PascalCase`. Units go in names (`idle_timeout_ms`).
- Build/run/test commands live in each sub-project's `README.md`.

## Hard rules

- Data safety rules in `docs/conventions.md` §4 are never weakened without asking Hao.
- Work outside the current milestone goes to "Later" in `docs/roadmap.md`, not into code.
- A design change adds a row to `docs/decisions.md` and updates `docs/architecture.md` in the same commit.
- Update the status lights in `docs/roadmap.md` when a milestone check passes.
