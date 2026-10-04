# Gate receipt: bin/gate full run — 2026-10-04

- Subject: `bash bin/gate` on /Users/sac/ash_pplan, run to completion (log: /tmp/bin-gate-full.log, ~12.9k lines)
- Overall: **GATE FAILED** (exit code 1; 10 failing steps listed in the GATE FAILED footer)
- Runtime: ~28 min
- Nothing fixed, nothing deleted, no git commands.

## Step table (in run order)

| # | Step | Result |
|---|------|--------|
| 1 | conform | PASS |
| 2 | conform-falsify | PASS |
| 3 | ggen-ecosystem parses ontology.ttl | PASS |
| 4 | ggen-doctor (pack ontology/gate/template/NIF/oxigraph health) | FAIL |
| 5 | mix deps.get --check-locked | PASS |
| 6 | mix hex.audit | FAIL |
| 7 | mix deps.unlock --check-unused | FAIL |
| 8 | mix format --check-formatted | FAIL |
| 9 | mix compile --warnings-as-errors | PASS |
| 10 | mix check | FAIL |
| 11 | mix test on the declared Elixir floor | SKIP (Elixir 1.17 not on PATH; CI leg covers it) |
| 12 | manufacture leaves generated source unchanged | FAIL |
| 13 | pack-gate-witness-court (per-gate negative evidence) | PASS |
| 14 | ggen-replay-court (receipt replay as a court) | FAIL |
| 15 | ggen-replay-court --dry-run-preview (drift preview) | PASS |
| 16 | receipt-chain-verify (parent_hash + payload hash court) | PASS |
| 17 | provenance-verify (vendor provenance.ttl digest court) | FAIL |
| 18 | verify-package | FAIL |
| 19 | ggen-verify (fail-closed pack verify) | FAIL |
| 20 | receipt | PASS |

## Failure classification

### (a) This session's new steps
- **provenance-verify**: FAIL — 8 digest mismatches between the vendor verify lock and the
  on-disk gate files (lock was not regenerated after gate edits):
  - `state-transition-pack/gates/010_no_skipping_executed.rq`
  - `state-transition-pack/gates/030_reachable_states.rq`
  - `state-transition-pack/gates/040_chain_policy_supported.rq`
  - `evidence-standing-pack/gates/010_no_receipt_no_standing.rq`
  - `evidence-standing-pack/gates/040_algorithm_supported_set.rq`
  - `evidence-standing-pack/gates/060_outcome_requires_pending.rq`
  - `evidence-standing-pack/gates/065_standing_only_on_outcome.rq`
  - `under priv/ggen/vendor/*/gates/` (verify_lock MISMATCH lines 11717ff)
- **receipt-chain-verify**: PASS — GREEN, 307 receipts hash-verified, 181 chains link-verified,
  head extended 294 -> 307. Not a failure.

### (b) Pre-existing environment steps
- **mix hex.audit**: FAIL — earmark 1.4.49 advisory EEF-CVE-2026-48591 (MEDIUM, stored XSS),
  retired-package findings. Dependency advisory, not session work.
- **mix deps.unlock --check-unused**: FAIL — 7 unused lock entries: earmark, email_checker,
  flop, html_sanitize_ex, mochiweb, money, query_builder.
- **mix format --check-formatted** / **mix check**: FAIL — single unformatted file OUTSIDE the
  repo: `/Users/sac/ash_pplan/test/petal_framework/demo_graph/deps/phoenix/lib/phoenix/router/console_formatter.ex`
  (a vendored phoenix dep under test/petal_framework; nothing in ash_pplan's own tree).
- **ggen-doctor**: FAIL — SCHEMA DRIFT on `ash-pplan-store-conformance-pack`: doctor output
  contains no JSON document (only mix noise or empty). All other packs ok.
- **verify-package**: FAIL — `hex` package build crashed in
  `Ash.Resource.Transformers.RequireStringLengthCountConfig.transform/1` (ash 3.33.11 raises
  via Spark DslError; trigger at reactor/generic_action_bridge.ex:10 in the packed copy).
- **ggen-verify**: FAIL — SCHEMA DRIFT on 2 of 7 packs: `ash-pplan-pack` (data.gates: missing
  key 'passed'), `ash-pplan-workflow-pack` (envelope contains no JSON document, only mix noise);
  5 other packs PASS.

### (c) Generated-unchanged drift
- **manufacture leaves generated source unchanged**: FAIL — regeneration would change:
  - `/Users/sac/ash_pplan/lib/ash_pplan/catalog/projection_catalog.ex`
  - `/Users/sac/ash_pplan/lib/ash_pplan/examples/workflows/selfhost.ex` (properties drift:
    `[]` vs generated `[:compensable, :observable]` / `[:observable]`)
  - `/Users/sac/ash_pplan/test/support/examples/workflows/ultracode.ex` (same properties
    drift, plus `[:durable]` vs `[:durable, :resumable]`)
- **ggen-replay-court**: FAIL — 33 receipts with "official replay drift: output state
  changed" + 2 with "receipt has no post_run_hash" (rcpt_5816c30d0bc8b365,
  rcpt_671adb5cab8a0b95), and 3 template replays with "official replay drift: ontology
  changed": `priv/ggen/ash-pplan-dsl-pack/templates/{dsl_extension.ex,lift.ex,wrapper.ex}.eex`.
- Receipt file written per lane contract: /Users/sac/ash_pplan/receipts/gate-bin-gate-2026-10-04.md
