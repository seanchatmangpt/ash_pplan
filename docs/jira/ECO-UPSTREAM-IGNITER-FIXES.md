# ECO-UPSTREAM-IGNITER-FIXES

# ECO-UPSTREAM-IGNITER-FIXES — Upstream ggen_igniter fixes from the 2026-10-04 ERRC lanes

Status: prepared, local branch only (no push, no PR). Upstream repo: `/Users/sac/ggen_igniter`.

## Branch

`errc-igniter-envelope-and-chain-fixes` @ `df6b0b94d9a1963476ac6d282dc2ab83632bc579`, parent `90a5c63` (v26.10.5).

## Fix 1 — Parser `passed` contract (verify envelope)

**Files**: `lib/mix/tasks/ggen_igniter.verify.ex`

The `--json-envelope` builder emitted `data.gates.passed` only on passing runs
(`gate_json/1`'s `{:ok, results}` clause); the two failing variants
(`gate_failed`, `gate_cardinality`) omitted the key entirely. Consumers that
parse `passed` as a required key of the envelope contract classified a
legitimate FAIL envelope as schema drift instead of reading `status`.

**Change**: `passed` is now unconditional — an empty list on every failing
variant. `status` remains the sole pass/fail discriminator; `passed` is
payload, never a verdict. Backward compatible: consumers keying on `status`
are unaffected; consumers keying on `passed` presence now see `[]` instead of
a missing key on FAIL.

**Test**: `test/mix/tasks/ggen_igniter_verify_task_test.exs` gate_cardinality
assertion updated (`"passed" => []`); the passing-path test already asserted
`gates.passed` membership. Result: the unlawful-pack test that failed on HEAD
passes on the branch; the two remaining failures in that file are pre-existing
(invocation exit codes: task halts 2 per `docs/reference/cli/exit-codes.md`,
tests expect 1 — stale tests, unchanged by this diff, present on HEAD).

## Fix 2 — Receipt parent_hash writer bug

**Files**: `lib/ggen_igniter/reactors/reconcile_reactor.ex`

All receipts were written with `parent_hash: nil` because every
`Receipt.new/1` call site passed no `base_dir` opt, so
`GgenIgniter.Receipt.new/2`'s `put_new_parent_hash/2` never fired (its guard
requires a binary `base_dir` AND a binary `recipe_key`).

**Change**: all three `Receipt.new` call sites in `ReconcileReactor` now pass
`base_dir: manifest_dir`:

- `:alive` receipt in `finalize_evidence` (`recipe_key: single_recipe && single_recipe.recipe_key`) — the primary fix: recipe-keyed runs now link to their chain tail via `reconstruct_standing/2`.
- Two failure-path receipts (`:compensation_failed` and the generic failure receipt) — contract-correct form only; `recipe_key: nil` keeps them honestly rootless by design.

**Migration semantics**: existing receipts keep their nil `parent_hash` —
honest rootless, NOT backfilled. Only receipts written after this change link
to their recipe_key's chain tail. `GgenIgniter.Receipt.new/2` itself is
unchanged; no consumer changes needed.

**Test**: `test/ggen_igniter_receipt_test.exs` already covers the
chain-linking behavior of `new/2` with `base_dir` (48/48 pass, unchanged);
`ggen_igniter_finalize_evidence_retry_safety_test.exs` 1/1 pass.

## Item 3 — OFFENDER-vs-WITNESS gate convention (NOT decided — documented for maintainers)

Two contradictory gate scoring conventions coexist in the repo:

- **Witness-reporting**: `GgenIgniter.GateVerify` (and therefore
  `mix ggen_igniter.sync`, `mix ggen_igniter.verify`'s gate half) treats
  >= 1 row as PASS. The rows are witnesses the ontology must produce.
  Zero rows = FAIL. Fails open against conjunctive SELECTs — this is the
  failure mode `mix ggen_igniter.verify`'s cardinality contracts exist to
  close (see the verify task's moduledoc for the measured Book/BookResource
  and amp:evidence examples).
- **Offender-reporting**: the vendored state-transition / evidence-standing
  gates treat rows as offenders — 0 rows = clean/PASS, >= 1 row = FAIL. The
  inverted `verify/*.unbound.rq` queries are offender-reporting.

**Option A — keep both, document the split (minimal blast radius)**: witness
gates live under `gates/`, offender gates under `verify/` — the directory IS
the convention. Any new gate type must declare which side it is.

- Blast radius: documentation only. But the directory split is only enforced
  by `Pack.discover_queries/1`'s glob; nothing TYPEs a gate as offender-style,
  so an offender query placed in `gates/` still fails open (scores :pass
  exactly when broken).

**Option B — explicit per-gate convention flag in `cardinality.json`**
(e.g. `"mode": "offender" | "witness"` per gate, witness default).

- Blast radius: `GgenIgniter.GateVerify.load_cardinality/1` (parse),
  `GateVerify.run/2` (inversion per flag), `verify/cardinality.json` in
  every shipped pack (`priv/ggen/*-pack/verify/cardinality.json`,
  `test/fixtures/ash_manufacture_pack/verify/cardinality.json`), the verify
  task's envelope (`data.gates` gains a per-gate mode echo), and every pack
  authored against the >= 1-row default elsewhere in the ecosystem. Larger,
  but closes the "offender query in gates/ fails open" hole.

**Recommendation shape for maintainers** (not decided here): if the ecosystem
has packs authored against the >= 1-row default that ship no contract file,
Option B's default must remain witness so those packs' behavior is unchanged;
Option A is the zero-risk interim and can be promoted to Option B later
without breaking the directory convention.

## Reproduction

```sh
cd /Users/sac/ggen_igniter
git checkout errc-igniter-envelope-and-chain-fixes
GGEN_TEST_FULL=1 MIX_BUILD_ROOT=_build-envfix \
  mix test test/mix/tasks/ggen_igniter_verify_task_test.exs \
           test/ggen_igniter_receipt_test.exs \
           test/ggen_igniter_receipt_schema_test.exs
```

`MIX_BUILD_ROOT` isolates the build; delete `_build-envfix` after.
