# HaoTranNAS docs

Author: Hao Tran · 2026-11-18

## Read in this order

| # | Doc | Answers |
|---|---|---|
| 1 | [concepts.md](concepts.md) | What ideas is this built on? |
| 2 | [architecture.md](architecture.md) | How does the system work? |
| 3 | [roadmap.md](roadmap.md) | What do we build, in what order, and where are we now? |
| 4 | [decisions.md](decisions.md) | What did we decide, and why? |
| 5 | [conventions.md](conventions.md) | Rules that keep every sub-project in the same shape |
| 6 | [community-research.md](community-research.md) | Who else does this, and what we borrowed |
| 7 | [build-log.md](build-log.md) | What was built in each wave, and why (the lessons) |

## One topic, one home

Each fact lives in exactly one place. Other docs link to it instead of copying it.

| Topic | Single source of truth |
|---|---|
| Ideas and theory | `docs/concepts.md` |
| System design | `docs/architecture.md` |
| Plan and status | `docs/roadmap.md` |
| Decisions | `docs/decisions.md` |
| Working rules | `docs/conventions.md` |
| Wire format and messages | `protocol/spec.md` + `protocol/vectors/` |
| How to build / run / test a part | `<sub-project>/README.md` |
