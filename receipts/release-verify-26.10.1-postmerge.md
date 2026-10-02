# Release Verify 26.10.1 — Post-Merge Re-Verification (G7)

## Subject

- **Branch verified**: `docs/diataxis-fanout` @ `0e5f65f96f260c246416470ddb91195a8aeb9ee7`
- **NOT main.** G1's merge did not land within the 20-minute poll window
  (`origin/main` stayed at `1a3d86aaa5bf6f2a7f4cc5b750fe619c0189bd37`
  "test(manufacture): courts clean up their unique build roots and manifest dirs");
  per lane contract this verification was run on `docs/diataxis-fanout` and is
  labeled accordingly.
- Build root: `MIX_BUILD_ROOT=_build-g7` (isolated, cold build).

## 1. Package verification (`bin/verify-package`)

Result: PASS — `package ash_pplan-26.10.1 compiles from its own contents`
(MIX_ENV=prod, --warnings-as-errors, in an unpacked throwaway dir).

Tarball: `ash_pplan-26.10.1.tar` (287744 bytes)

```
SHA256: 1b7ba877056475fc7dcc77311ec9b2cb2df45f08c457647f3322c08345aee3c5
```

## 2. Spot tests (`test/release_contract_test.exs` + `test/manufacture_test.exs`)

Result: **FAIL** — 44 tests, 1 failure (803.5 s, seed 188604).

Failing test: `test mutation: a hand-edited generated file is caught by the
byte-identical comparison` (`test/manufacture_test.exs:146`).

- First run: `ExUnit.TimeoutError` at 60 s (line 173, `System.cmd`).
- Re-run with `--timeout 600000`: completed in 155.8 s and failed a real
  assertion — `assert File.read!(path) == before, "the script did not
  regenerate over the hand edit"` (line 187). Not a timeout flake; the
  manufacture script failed to regenerate over an injected hand edit.

## Verdict

**NOT READY** for `mix hex.publish`.

Reasons:
1. The merge is not on `main` — this verification applies to
   `docs/diataxis-fanout@0e5f65f`, not `origin/main@1a3d86a`.
2. The manufacture mutation court fails: the generation script does not
   regenerate over a hand-edited generated file (byte-identical comparison
   gate not exercised successfully). This is a release-relevant determinism
   gate, and it is red on the exact tree the package was built from.

Re-run this verification on `main` after G1's merge lands and after the
manufacture regeneration failure is repaired, before publishing.
