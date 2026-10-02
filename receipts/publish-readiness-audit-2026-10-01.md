# Publish-Readiness Audit — Lane P10 — 2026-10-01

Adversarial publish-readiness audit of three release candidates. READ-ONLY lane;
only this file written. Evidence: real `./bin/verify-package` (ash_pplan),
`mix hex.build` on all three, tarball unpack + grep on all three, hex.pm API
queries, git tag inventories.

## ash_pplan (HEAD db06dc8, docs/diataxis-fanout == origin/main, version 26.10.1)

- NOTE — mix.exs `@version "26.10.1"` and CHANGELOG head entry is 26.10.1, not
  26.10.2 as briefed. Content checks below are against the actual 26.10.1 entry.
- NOTE — working tree not clean: `test/manufacture_test.exs` modified (24+/11−),
  two untracked receipts. Package contents unaffected (test/ not in `files:`),
  but the release commit/tag must be cut from a clean tree.
- NOTE — audited on branch `docs/diataxis-fanout`, which is exactly even with
  origin/main (0 ahead / 0 behind, same tip db06dc8); audit is on-main-equivalent.
- PASS — `MIX_BUILD_ROOT=_build-p10 ./bin/verify-package` exit 0:
  "package ash_pplan-26.10.1 compiles from its own contents".
- PASS — package metadata: MIT license, GitHub link, `files:` includes lib, priv,
  bin, ontology.ttl, ontology, planning, docs, ecosystem.lock.toml.
- PASS — `Durable.Store` behaviour + `Store.Dets` (dets.ex, ets.ex) and all six
  generated ggen packs (workflow, durable-chaos, durable-tla, store-conformance,
  standing, pack) are present in the built tarball contents.
- PASS — secret sweep of unpacked tarball (password/api_key/secret/apikey/token
  patterns, private keys, ghp_/github_pat_): zero hits.
- MAJOR — **no git tags at all** (local `git tag` count 0, zero remote tags).
  Neither v26.9.8 nor the 26.10.1 release is tagged. CHANGELOG accuracy for
  26.10.1 is therefore not checkable against a tagged baseline, and the release
  has no immutable identity. Tag v26.10.1 before publish.
- MINOR — CHANGELOG 26.10.1 spot-checks pass (durable engine, packs, NOTICE,
  gates all exist as described) but with zero tags the entry cannot be
  diff-verified against 26.9.8; the entry itself admits CI standing UNKNOWN.

## ash_ex4pm (main @ 1621d21, version 26.10.2)

- PASS — `mix hex.build` succeeds; checksum
  ebbe6a29afce86c48ca378c1da39f8059af08f019661d6dcbdc2bd0fe88a02a6.
- PASS — broadcaster code ships: `lib/ash_ex4pm/notifier.ex` present in the
  unpacked tarball with the app-env broadcaster threaded into
  `Ex4pm.Stream.Ingest.ingest_envelope/2`.
- PASS — CHANGELOG 26.10.2 entry accurate: covers broadcaster (88e1698),
  capability registry + Diátaxis (56f0c1a), and the docs commit 491d7ee; no
  changes since v26.10.1 that the entry omits.
- PASS — secret sweep: zero hits in the tarball.
- MAJOR — **docs/ directory is entirely absent from the tarball**, while
  `docs/0` config in mix.exs lists `docs/INDEX.md`,
  `docs/reference/capabilities.md`, `docs/explanation/architecture.md`,
  `docs/PRD-ARD-v26.10.2.md` as extras (all tracked in git). Hex's default
  packaging excludes docs/, and there is no `files:` list to re-include it, so
  `mix docs` from the published package will fail to find every extra and the
  26.10.2 capability/Diátaxis documentation story — the headline of this
  release — will not appear on hexdocs. Add `files:` including docs (or trim
  extras) before publish.
- MAJOR — **no v26.10.2 tag** (local or remote; only v26.9.10 and v26.10.1
  exist). Tag before publish.
- NOTE — no `files:` list at all in mix.exs; besides docs/ this also silently
  ships/excludes whatever hex defaults decide. Explicit `files:` recommended.
- MINOR — `docs/PRD-ARD-v26.10.2.md` is listed as a doc extra; publishing a
  per-version PRD as a hexdoc extra is a maintenance smell, not a gate.

## ggen_igniter (main @ 5f4a1b0, version 26.9.31)

- PASS — `mix hex.build` succeeds; checksum
  8899da01d4bab8609852008bb39ac2fbf936a5162f61a0fbb262bc5d0cab3e1f.
- PASS — CHANGELOG v26.9.31 section accurate against git log: the five Wave B
  packs (6f204cb, 345ac5b, a6e6b7d, 0deeb27, cbfbfcc), test harness
  (2cf3a75), refusal-code additions (8a307eb, 167c61a), and the graphlaw wasm
  engine (5f4a1b0) are all present and correctly described.
- PASS — secret sweep: zero hits.
- MAJOR — **graphlaw engine is not runnable for hex consumers out of the box.**
  The wasm artifact is NOT in the package (wasm-artifacts/ ships only
  tera_wasm_renderer.wasm; no graphlaw_wasm.wasm). Resolution is app env
  `:ggen_igniter, :graphlaw_wasm_path` or default
  `~/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm` — an external,
  un-published repo built with cargo. To the briefed docs-gap question, the
  evidence partially refutes the premise: the override and the missing-artifact
  fast-fail ARE documented in both the module doc and the packaged README
  (README "Engines" section, graphlaw.ex moduledoc). The remaining gap is
  operational, not documentary: hex consumers cannot use `--engine graphlaw`
  without cloning and building an unpublished repo. Either ship the wasm
  artifact, or publish graphlaw separately and state the requirement as a
  dependency, or accept and mark the engine experimental.
- MINOR — **no v26.9.30 or v26.9.31 tag** (local or remote; latest is
  v26.9.15... latest actually v26.9.8 by tail; v26.9.30/31 absent). Tag before
  publish.
- NOTE — `native/ggen_graph_nif` ships in the tarball; NIF-based packages need
  precompiled-binaries policy/attention on hex.pm.

## Cross-repo

- PASS — CalVer consistent: 26.10.1 / 26.10.2 / 26.9.31 all follow
  YY.M.D-patch convention used across the ecosystem.
- PASS — no hex.pm version collisions: ggen_igniter latest 26.9.29 (26.9.31
  free), ash_ex4pm latest 26.10.1 (26.10.2 free), ash_pplan not yet on hex
  (26.10.1 free). ex4pm already at 26.10.1, consistent with ash_ex4pm's pin.
- FAIL pattern — tags: ash_pplan 0 tags; ash_ex4pm missing v26.10.2; ggen_igniter
  missing v26.9.30 and v26.9.31. All three releases lack immutable identity.
- NOTE — dependency skew: ash_pplan pins ex4pm `== 26.9.30` + ash_ex4pm git
  ref 735ab7c (self-described as still declaring ex4pm 26.9.9, override: true),
  while ash_ex4pm 26.10.2 pins ex4pm `== 26.10.1`. Once ash_ex4pm 26.10.2 is on
  hex, ash_pplan's git pin + override becomes stale and should be re-pinned.

## Final table

| Repo | Version | verify gate | Tarball contents | CHANGELOG accuracy | Secrets | Tags | Verdict |
|---|---|---|---|---|---|---|---|
| ash_pplan | 26.10.1 | PASS (exit 0) | PASS (Store.Dets + 6 packs) | PASS (spot-check; no tag baseline) | PASS | MAJOR: none exist | NOT READY |
| ash_ex4pm | 26.10.2 | hex.build PASS | MAJOR: docs/ missing vs docs extras | PASS | PASS | MAJOR: no v26.10.2 | NOT READY |
| ggen_igniter | 26.9.31 | hex.build PASS | MAJOR: graphlaw wasm not shippable/useable | PASS | PASS | MINOR: no v26.9.30/31 | NOT READY |

## BLOCKER/MAJOR list

- BLOCKER (none): no gate failure, secret, or license/collision blocker found.
- MAJOR — ash_pplan: zero git tags; tag v26.10.1 before publish.
- MAJOR — ash_ex4pm: docs/ missing from tarball while docs extras reference it
  → hexdocs build will fail; add `files:` including docs or trim extras.
- MAJOR — ash_ex4pm: no v26.10.2 tag.
- MAJOR — ggen_igniter: graphlaw wasm artifact not packaged and not obtainable
  by hex consumers (external unpublished repo + cargo build); docs do explain
  the env override and fast-fail, so remediate by shipping/publishing the
  artifact or marking the engine experimental.
- MINOR — ggen_igniter: no v26.9.30/v26.9.31 tag; native/ NIF ships without a
  precompiled-binaries policy.
- MINOR — ash_pplan: CHANGELOG not diff-verifiable (no tagged baselines);
  dirty working tree at audit time.
