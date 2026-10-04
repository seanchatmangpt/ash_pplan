# Case Study: <title>

> Copy this template for new case studies (`_template.md` -> `<name>.md`).
> Every `<<...>>` slot is a number or claim that MUST carry its source artifact
> per the [honesty contract](README.md#honesty-contract). No slot may be left
> uncited.

## Situation

What process was mined, on which subject.

- Subject: `<<repo/workflow identifier, exact tree state>>`
  — Source: `<<git SHA or working-tree date, e.g. "working tree 2026-10-03">>`
- Process: `<<workflow name, e.g. "release" durable run on Store.Dets>>`
- Question the study answers: `<<one sentence>>`
- Environment: `<<aarch64 / OTP 28 / Elixir 1.19.5, 16 schedulers — cite the
  baseline header or demo receipt header>>`

## Mining evidence

What the ledger shows, and where the numbers come from.

| # | Metric | Value | Source artifact | Trust |
|---|---|---|---|---|
| M1 | `<<e.g. ledger_ocel_events_1k µs/op>>` | `<<value>>` | `<<bench/fleet/*.json | bench/*.json | docs/demonstration.md row | test/...>>` | `<<fresh / medium / load-noisy per BASELINES-CANONICAL>>` |

- Event log: `<<OCEL export path or generation command>>`
  — Source: `<<e.g. ledger_ocel_export_1k row, bench/BASELINES-CANONICAL.md §1>>`
- Digest: `<<content digest line>>`
  — Source: `<<same artifact>>`

## Actions

What was changed or refused because of the mining evidence. Each action cites
the metric that motivated it.

- A1: `<<action>>` — motivated by `<<M#>>`; implemented/verified in
  `<<commit, test file, or bench receipt>>`
- Refusals: `<<typed refusal / SKIP rows — cite the row>>`

## Quantified outcome

Before/after, each side cited.

| # | Metric | Before | After | Before source | After source |
|---|---|---|---|---|---|
| Q1 | `<<metric>>` | `<<value>>` | `<<value>>` | `<<artifact>>` | `<<artifact>>` |

Superseded figures (kept, not deleted, per the honesty contract):

- `<<old figure>>` (`<<old artifact>>`) — superseded by `<<new figure>>`
  (`<<new artifact>>`), reason: `<<e.g. chain-digest fix invalidated pre-fix
  scaling>>`

## Reproduction

Exact commands to re-run the evidence chain.

```sh
# 1. run
<<mix test ... / mix run bench/... >>
# 2. standing receipt
<<test or bench that exercises Standing.receipt/2>>
# 3. OCEL export + digest
<<e.g. MIX_BUILD_ROOT=... mix run bench/store_scaling.exs ...>>
# 4. full demonstration receipt (overall verdict)
bin/demonstrate
```

Each command's expected evidence line: `<<exit code + last-line digest or
test-count summary>>`.
