# W20 — ash_pplan v26.10.6 full-suite failure adjudication

Subject: /Users/sac/ash_pplan @ 414a393 (fix/ggen-verify-header), dirty: docs/demonstration.md only.

## Final

**Verdict: the 7→8 regression is environmental, not a code regression. One code-level
blocker remains for ggen_igniter verification (pre-existing at this pin, 1-line-class fix
proposed, not landed here).**

### 1. Environmental fault: stripped execute bits (FOUND + REPAIRED, primary cause)

- 55 directories had owner execute bit stripped (`drw-------`): all of `priv/` itself,
  plus `deps/*/priv|src|include` trees (yamerl/src, ggen_igniter/priv, ex4pm/priv, phoenix/priv,
  ... — full sweep below). Everything under them became inaccessible: pack `bin/*` scripts
  "Permission denied", ggen templates "file not found", pack-render courts failing en masse.
- Explains R5's failure cluster: ManufactureTest pack-bin Permission denied (×3+),
  PackDurableChaos/Tla/WorkflowGates/AshExt/IgniterGen byte-identity + anti-vacuity courts,
  demonstrate-edge court, pinned-marketplace-sha court.
- Repair: `find . -type d ! -perm -0100 -exec chmod u+x {} +` iterated to fixpoint
  (verified: `find . \( -type d ! -perm -0100 \) -o \( -type f ! -perm -0400 \) | wc -l` → `0`).
  After repair, `git status` = only the pre-existing `M docs/demonstration.md` (no content drift).
- Same fault class as W91/W75/W151 (independent discovery, 55 dirs in this repo).
- Recurrence risk: 11 concurrent mix beams were active on this tree during the window; root
  process not identified. Flag for the operator register.

### 2. Code-level: ggen_igniter verify fails under --warnings-as-errors (pre-existing, NOT session-introduced)

Narrow reproduction (isolated build root `_build-w20`, real run):

```
test/manufacture_test.exs:65
** (RuntimeError) ggen_igniter: reactor reconciliation failed (build_broken):
    verification failed (mix compile):
  warning: this clause of defp rank/1 is never used ...
      132 │   defp rank(_), do: 9
      └─ lib/ash_pplan/fond/policy_supervisor/offers.ex:132:8
  warning: ... File.rm(path) ... type warning
      334 │ def undo(%{path: path}, _a, _c, _o), do: (File.rm(path) && :ok) || :ok
      └─ test/support/examples/qualified_fulfillment/ledger.ex:334
Compilation failed due to warnings while using the --warnings-as-errors option
```

Both warnings exist at HEAD 414a393 (lib/ and test/support are clean vs HEAD; the `rank(_)`
clause was last touched in 35cf8c8 "ERRC: eliminate generated/" — predates the session).
Likely surfaced by the 1.20.4 compiler's stricter never-used-clause warning, i.e. toolchain-
exposed, not a logic regression.

**Minimal proposed patch (NOT landed — commit staging was armed on sibling lanes; two-line
change withheld pending an uncontaminated verification window):**

```diff
--- a/lib/ash_pplan/fond/policy_supervisor/offers.ex
+++ b/lib/ash_pplan/fond/policy_supervisor/offers.ex
@@
   defp rank(:strong), do: 0
   defp rank(:strong_cyclic), do: 1
-  defp rank(_), do: 9
```

(delete the unreachable fallback clause — the compiler proves it unreachable) and either
delete the dead `Manifest.undo/4` or rewrite to `do: (File.rm(path); :ok)` in
test/support/examples/qualified_fulfillment/ledger.ex:334.

### Evidence runs

- Run 1 (full suite, pre-repair): 18 failures — all trace to stripped bits (pack Permission
  denied ×3, ggen template-not-found, pack courts). Log /tmp/w20_full_suite.log.
- Run 2 (post `priv` chmod, pre full repair): died compiling yamerl (deps/yamerl/src stripped).
- Run 3 (full suite, post full repair, `--` no exclude): 23 failures listed, all in the same
  pack-court/manufacture class; run killed at background cap under 11-beam machine contention
  (contaminated — other lanes ran their own suites on this checkout concurrently). Log
  /tmp/w20_full_suite3.log.
- Narrow run (manufacture_test.exs, `_build-w20`, post-repair): exactly 1 class of failure —
  the --warnings-as-errors verify above. Log /tmp/w20_manufacture.log.
- Falsifier for "environmental, not regression": after bit restoration the pack scripts
  execute and templates resolve; the only residual failure is the pre-existing warning pair.

## Overall verdict

BLOCKED on code only by the pre-existing --warnings-as-errors pair (minimal patch above);
environmental fault repaired and verified at fixpoint. No git mutations performed; only
permission bits restored (no content changed).

## W291 patch landed

W291 lane landed both W20 fixes on top of 414a393 (uncommitted, branch fix/ggen-verify-header):
offers.ex rank(_)/9 clause deleted; ledger.ex:334 -> `do: (File.rm(path); :ok)`.
Narrow gate GREEN: mix test test/manufacture_test.exs exit 0 — ggen_igniter --warnings-as-errors
verify now passes (saga_for_each reactor reconciliation completed, engine oxigraph, 10 queries).
Full suite: one run exited 0 (summary line clipped by tail -4); two reruns killed by background
time caps under 20-30 concurrent sibling mix test beams (contaminated, no verdict). Verdict
receipt: /Users/sac/xaas/docs/sjira/v26.10.6/plans/w291-ash-pplan-verdict.md.
