# Standing, receipts, and the ladder

`AshPPlan.Standing` (`lib/ash_pplan/standing.ex`) answers one question about a
workflow run: is it **alive** — did the plan that ran, the execution observed,
and the post-state after it all hold together — or **lost**, and if lost, which
layer broke and under which typed term.

## The three layers

`Standing.layers/0` returns them in order:

1. **`plan_correct`** — reads process-evidence events
   (`AshPPlan.ProcessEvidence.Event`), the workflow model, the provider
   selection, and FOND gates. Every executed task must belong to the model,
   run after its dependencies, run on the selected provider, and follow an
   admissible outcome path under the FOND gates (`run.fond_gates`: a gate task
   whose outcome is not admitted must have no successor events).
2. **`execution_correct`** — compares `run.execution`, an
   `{observed, wanted}` pair; equality means the run did exactly what was
   wanted, exactly once each.
3. **`observed_consequence_correct`** — judges named boolean checks over real
   post-state (`run.consequence`); fails with the names of the false checks.

Each layer is a reading of evidence or real state, never of a step's own
claim. Nothing in the module grants DO authority.

## verdict/3, verdicts/1, standing/1

- `Standing.verdict/3` combines three layer verdicts (`:ok | {:error, term}`)
  into `:alive` or `{:lost, broken_layers}` in layer order.
- `Standing.verdicts/1` computes all three layer verdicts of a run as a map.
- `Standing.standing/1` evaluates the run: `:alive` or `{:lost, broken_layers}`.

## Standing.ladder: the broken-term mapping

The "ladder" is the standing-vocabulary mapping between a broken layer and the
typed term the receipt carries. It lives in
`AshPPlan.Standing.Receipt.layer_term/1`
(`lib/ash_pplan/standing/receipt.ex`); there is no `Standing.ladder/0`
function — the mapping is a fixed table:

| Broken layer | Broken term |
|---|---|
| `plan_correct` | `mu_on_O` |
| `execution_correct` | `mu_unlawful` |
| `observed_consequence_correct` | `R_missing_consequence` |

A `REFUSED` standing without a `broken_term` fails the schema — every refusal
is typed (exercised in `test/standing_test.exs`).

## Receipt cost and caching

A receipt is deterministic: identical `{run, opts}` inputs always produce a
byte-identical receipt. Two consequences for performance:

- **Ledger digest is linear.** The evidence hash chain
  (`AshPPlan.Standing.Chain`, `lib/ash_pplan/standing/chain.ex`) once
  re-digested the whole chain per append (O(n²) over n events); the chain
  digest is now computed in O(n), so receipt cost grows linearly with the
  event ledger.
- **Repeat receipting is memoized.** `Standing.receipt_cached/2` wraps
  `receipt/2` in `AshPPlan.Standing.Cached`, an ETS LRU keyed on
  `sha256(term_to_binary({run, opts}))` (256 entries, single-flight cold
  fills, errors cached too). Determinism makes hits always safe: a cache hit
  returns the same bytes a recomputation would. See
  `docs/diataxis/reference/public-api.md` for the full API.
