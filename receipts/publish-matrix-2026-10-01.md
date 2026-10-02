# Publish Dry-Run Matrix — 2026-10-01 (lane P8)

`MIX_BUILD_ROOT=_build-p8-<name> mix hex.build` per repo; contents unpacked to
`/tmp/p8-matrix/<pkg>/pkg`, prod compile with `--warnings-as-errors`; `mix deps.get --check-locked`
and `mix hex.audit` in each source repo. No `mix hex.publish` was run. No git mutations.

| package | version | tarball sha256 | prod-compile | audit | notes |
|---|---|---|---|---|---|
| ash_pplan | 26.10.1 | `ae5bd31b0b595da2c4a45173102fb588de56d55c412d2142f2e2c1e231f6e169` | PASS | clean | tree dirty: `M test/manufacture_test.exs` (test only, not packaged). Hex checksum matches shasum. |
| ash_ex4pm | 26.10.2 | `ebbe6a29afce86c48ca378c1da39f8059af08f019661d6dcbdc2bd0fe88a02a6` | PASS | clean | tree has untracked `PUBLISH-26.10.2.md`, `_build-a1/`, `tmp/` (untracked, not packaged). |
| ex4pm | 26.10.1 | `3c764f9b028ed6ddabc06cb4a8051ddfa6c1cd1f21e83e0cb0298536b11fc979` | **FAIL** | **advisories** | **DIRTY TREE (another session's working tree — built from working tree, tarball is NOT a committed-HEAD artifact):** modified `CHANGELOG.md`, `docs/diataxis/reference.md`, `docs/thesis/chapters/generated_ocel_benchmark_tables.tex`. Prod compile fails: `GgenIgniter.Ontology.load!/1` and `GgenIgniter.Query.Oxigraph.run/2` undefined at `lib/mix/tasks/ex4pm.ggen.sync.ex:215/219` — ggen_igniter not available in the packaged dep closure. hex.audit: ash 3.33.1 advisories EEF-CVE-2026-93477 (MEDIUM), EEF-CVE-2026-86338 (MEDIUM), lazy_html 0.1.12 EEF-CVE-2026-92106 (LOW). |

## Details

- ex4pm hex.checksum (from hex.build) matches `shasum -a 256` for all three packages.
- ex4pm compile failures are real missing-module errors under `--warnings-as-errors`
  (module `GgenIgniter` not in the hex package's dep closure); compile without the flag would
  likely succeed but emit warnings — flagged as FAIL per the verify-package pattern.
- ex4pm has no dedicated verify-package script in `scripts/` (has `inspect-hex-package.py`);
  the standard unpack + prod-compile pattern was used.
- Scratch dirs left at `/tmp/p8-matrix/` for re-verification.
