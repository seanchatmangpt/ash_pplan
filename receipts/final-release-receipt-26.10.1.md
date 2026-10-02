# Final Release Receipt — ash_pplan v26.10.1 close-out (G8)

Date: 2026-10-01 · Lane G8 · Read-only aggregation of lanes A1/A4/A5/G7 plus beam4pm, ggen-marketplace, CI. No git mutations, no mix commands, no publish.

---

## 1. ash_pplan 26.10.1

### Version consistency
- `mix.exs`: `@version "26.10.1"` (line 4). CHANGELOG.md top entry: `## 26.10.1 - 2026-10-01`. Tarball on disk: `ash_pplan-26.10.1.tar`. **Consistent.**
- Tarball checksum (sha256, current working tree): `a99c09be2150a4f74c3bb4f5b2887938e1ee5778f5121ae2857acfe1c9e94fb3` — re-verified on disk 2026-10-01, matches the A5 dry-run receipt exactly. **However** the tree has advanced past the dry-run head d32cb9c (main is now at `1a3d86a`), so the dry-run checksum does NOT certify the current main content; recompute after final merge (this is G7's job, below).

### Release ladder (from receipts/publish-dry-run-26.10.1.md, lane A5, head d32cb9c)
| Step | Exit | Result |
|---|---|---|
| `mix deps.get --check-locked` | 0 | 88 deps unchanged vs mix.lock |
| `mix hex.audit` | 0 | No retired or security-advisory packages |
| `mix format --check-formatted` | 0 | Clean |
| `mix compile --warnings-as-errors` | 0 | 134 files, zero warnings |
| `./bin/verify-package` | 0 | Package compiles from its own contents (prod env, from unpacked tarball) |

### Suite status
- Last known full-suite observation: **1240 tests, 2 failures** (manufacture-drift family). Since then: `d84c417 fix(durable): serialize cancel against migration via the claim CAS; regenerate; real mutation court`, `3243717 fix(ci): remove duplicated migration clause...`, `1a3d86a test(manufacture): courts clean up their unique build roots...`, and `f0643f1 ... regenerated artifacts` — all in the regeneration/fix family that targets the drift class. **No fresh full-suite receipt naming the 2 failures fixed exists on disk** (no ref-bump notes in receipts/), and the post-merge verify (G7, `receipts/release-verify-26.10.1-postmerge.md`) has **not landed** after 15 minutes of polling. Suite state on exact current main: **UNKNOWN, pending G7**.

### hex.audit: PASS (exit 0). 

### Lock standings (ecosystem.lock.toml v26.10.1 + receipts/ggen-ecosystem-observation-2026-10-01.md)
| entry | standing | evidence / stale_reason |
|---|---|---|
| `[ggen_ecosystem]` digest sha256:917eb72a... | **OBSERVED** (UNKNOWN→OBSERVED) | `docker manifest inspect` on the exact pinned digest succeeded; amd64+arm64 index present. `image_build_head` 0fa1c5c9 / run 33926356178 remain STALE (pre-v26.9.29); exact-head CI observation outstanding before re-promotion. |
| `[ggen_igniter]` sha 0abed8a3 (v26.9.30) | pinned, exact-head standing not re-verified | transport git exact-ref; upstream existence observed (gh api). |
| `[conformance]` rdflib 7.6.0 / pyshacl 0.40.1 | carried, no counter-evidence | not re-verified against live env this session |
| `[ash]` 3.33.11 (floor 3.33.11, EEF-CVE floor) | OBSERVED | mix.lock exact match |
| `[reactor]` 1.0.7 | OBSERVED | mix.lock exact match |
| `[ash_state_machine]` 0.2.13 | OBSERVED | mix.lock exact match |
| `[ash_oban]` 0.9.0 | OBSERVED | mix.lock exact match |
| `[durable_engine]` | **UNKNOWN** | CI not run on this change set; digests not re-observed |
| `[dev_test_dependencies]` (incl. ex4pm 26.9.30 override, ash_ex4pm ref 735ab7c3) | **UNKNOWN** | mix.lock matches, but CI not run, digests not re-observed; ash_ex4pm remote ref not probed |

### Docs gap (flagged, not fixed)
mix.exs has no `ex_doc` — package publishes without hexdocs HTML. Decline docs prompt at publish or add ex_doc first.

---

## 2. ash_ex4pm 26.10.2

- Release commit **exists locally**: `88e1698 chore(release): ash_ex4pm 26.10.2 — realtime broadcaster opt`.
- **NOT pushed**: local main is `ahead 1, behind 1` vs origin/main, with a **live merge conflict (`UU CHANGELOG.md`)** and a staged `.github/workflows/ci.yml` modification in the working tree. The repo is mid-merge, not releasable as-is.
- Checksum (expected, from PUBLISH-26.10.2.md): `5fd968f77fcbc96382b8a3e7cc6f9c613f8499be59aa4fcb5e321db61585721c`.
- Checklist: `/Users/sac/ash_ex4pm/PUBLISH-26.10.2.md` — 8 steps: confirm release state, hex credentials (`mix hex.user whoami`), `mix hex.build`, checksum verify, tarball-content verify (`broadcaster_opts` in notifier.ex), **real publish (USER-GATED)**, post-publish fetch verify, then downstream bumps (`ash_pplan`/`beam4pm` → `~> 26.10.2` only after hex.pm confirms live).
- CI on that repo is BLOCKED_UPSTREAM_TLS per its session receipt — publish must run from the laptop.

---

## 3. beam4pm

- **Pushed main SHA: `d7d9b329`** (`merge: pull realtime evidence + vendor bump from origin/main`) — confirmed on origin/main.
- Local main is ahead 2 of origin (a81c3d37, cab7a3a0 — wave receipt + admissions, unpushed) with a dirty `vendor/ggen-marketplace` submodule pointer. Not release-blocking for the pushed SHA.
- Realtime capture feature: **realtime Ash-action OCEL v2 capture via ash_ex4pm broadcaster** (`04a34363 feat(evidence): realtime Ash-action OCEL v2 capture via ash_ex4pm broadcaster`, merged in `830086b3`), adopted at v26.10.1 (cab7a3a0/a81c3d37).

---

## 4. ggen-marketplace

- Branch `spark-closure-courts`, receipt commit **`7669fd0a`** ("Spark ⟷ Implementation closure receipt — ash-extension-pack"). Base 3e4f65cc.
- 10-court verdict: **C1–C9 all PASS, C10 CONFORMANT (CONFORMANT_WITH_UNSUPPORTED_GAPS)**. Every court anti-vacuity-proven both directions with real runs.
- Open items (from the receipt itself):
  1. ggen_igniter 26.9.3 does not substitute `{{ package_name }}` in frontmatter `to:` under `for_each` — per-spec rendering needs CLI `--out` or an upstream fix.
  2. `install.ex.tmpl` installerRuntimeDep pipe-split renders a non-compiling dep for rows without `|` (pre-existing).
  3. `ash_pack_live_fixture.sh` only copies `test/*_composition_test.exs` into the live capsule; currently REFUSED by wasi-json-abi-pack's in-progress gate README.
  4. `formatterModule` declared but no template generates it (C7 stub compensates).
  5. Pack gates 110/120 added; repo gate tooling must run on next sync.

---

## 5. CI status — ash_pplan main

```
completed  cancelled  test(manufacture): courts clean up their unique build roots...  main  36890486274  30m30s
completed  cancelled  fix(ci): remove duplicated migration clause; block-form fond...   main  36885282071  30m30s
completed  failure    fix(durable): serialize cancel against migration via the claim CAS... main 36882801102 12m45s
```

Latest two runs **cancelled** at ~30m; the prior run failed. **No green exact-head CI run on main.** This is the gate blocking promotion of `[durable_engine]`/`[dev_test_dependencies]` standings.

---

## 6. Remaining BLOCKED / UNSUPPORTED items

| item | status | reason |
|---|---|---|
| ash_pplan exact-head CI on main | BLOCKED | two consecutive ~30m cancellations (timeout-class), prior run failure; no green run |
| G7 post-merge verify receipt | BLOCKED/ABSENT | `receipts/release-verify-26.10.1-postmerge.md` did not appear after 15 min of polling |
| `[durable_engine]` standing | UNKNOWN | CI not run on this change set; digests not re-observed |
| `[dev_test_dependencies]` standing | UNKNOWN | CI not run; ash_ex4pm ref 735ab7c3 remote existence not probed |
| `[ggen_ecosystem]` re-promotion | blocked (residual) | sha/image_build_head/observed_success_run predate v26.9.29; exact-head CI observation outstanding |
| hexdocs for ash_pplan | UNSUPPORTED (packaging gap) | no ex_doc in mix.exs; publishes without docs |
| ash_ex4pm CI publish | BLOCKED_UPSTREAM_TLS | publish must run from laptop per session receipt |
| ash_ex4pm push | BLOCKED | mid-merge with `UU CHANGELOG.md` conflict, behind origin by 1 |
| ggen-marketplace live-capsule chain | REFUSED | `ash_pack_live_fixture.sh` blocked by wasi-json-abi-pack gate README; new courts not in live chain |
| ggen_igniter `for_each` frontmatter substitution | UNSUPPORTED upstream | 26.9.3 does not substitute `{{ package_name }}` in `to:` under for_each |

---

## 7. FINAL VERDICT: **NOT READY**

`mix hex.publish` for ash_pplan 26.10.1 is blocked on exactly this list:

1. **Green CI on main.** Latest run cancelled at 30m30s, one before it the same, the one before failed. No exact-head ALIVE observation exists for the content that would ship.
2. **G7 post-merge verification receipt absent** (`receipts/release-verify-26.10.1-postmerge.md` did not land within the 15-minute poll window). It must deliver: post-merge tarball checksum on main (the dry-run checksum `a99c09be...fb3` was taken at d32cb9c and does not certify current main `1a3d86a`), and a full-suite run confirming the manufacture-drift 2 failures are fixed.
3. **Suite status unconfirmed on exact head** — 1240 tests / 2 failures is the last record; the regeneration commits (`f0643f1`, `d84c417`, `1a3d86a`) target that family but no receipt on disk witnesses a clean run.
4. **Hex publish credential** with publish scope (`mix hex.user whoami`).
5. **USER-GATED publish decision** — `mix hex.publish` is explicitly operator-gated; run from the laptop (CI TLS blocked for the sibling repo; same caution applies).
6. **Docs decision** — publish without hexdocs (decline the docs prompt) or add ex_doc first. Not blocking, must be chosen explicitly.

Non-blocking but adjacent: ash_ex4pm 26.10.2 is committed locally but NOT pushed (mid-merge, `UU CHANGELOG.md`); its publish is separately user-gated and must complete before ash_pplan/beam4pm bump to `~> 26.10.2`.

Once items 1–5 clear (CI green, G7 receipt on disk with a recomputed main checksum + clean suite, credential present, operator says go): run `mix hex.publish` from main, then verify the published checksum.
