# CalVer Policy + Tag Audit — 2026-10-01

Lane P9. Read-only git audit across six repos. Evidence: `mix.exs` / manifests,
`CHANGELOG.md` heads, `git tag | tail -5`, CONTRIBUTING / CHANGELOG policy prose.

## Per-repo table

| repo | version declared | declared where | CHANGELOG head | tags (tail -5) | tags CalVer? | stated policy |
|---|---|---|---|---|---|
| ash_pplan | 26.10.1 | `mix.exs` `@version "26.10.1"` (L4) | `## 26.10.1 - 2026-10-01` | (none — zero tags) | n/a (no tags exist) | none found (no CONTRIBUTING) |
| ggen_igniter | 26.9.30 | `mix.exs` inline `version: "26.9.30"` (L9) | `## v26.9.31 (unreleased)` — "mix.exs `version:` stays 26.9.30 until release" | `v26.9.30` not present; tail: v26.8.29, v26.8.30, v26.9.15, v26.9.3, v26.9.8 | yes (vYY.M.P, non-zero-padded M) | EXPLICIT: CONTRIBUTING.md L66-69 — "Versions are CalVer (vYY.M.D style; latest published on hex.pm); `mix.exs version:` must match topmost CHANGELOG heading; `mix ggen_igniter.doctor` checks it. Release bumps by maintainer." |
| ash_ex4pm | 26.10.2 | `mix.exs` `@version "26.10.2"` (L4) | `## [26.10.2] - 2026-10-01` | v26.9.10, v26.10.1 | yes | none in CONTRIBUTING (absent); policy lives in CHANGELOG notes: ex4pm exact-pin, "ex4pm's third CalVer component carries contract changes" |
| ex4pm | 26.10.1 | `mix.exs` `@version "26.10.1"` (L18) | `## [Unreleased]` then `## [26.10.1] - 2026-10-01` | v26.10.1, v26.8.27, v26.8.28, v26.9.30, v26.9.9 | yes | implicit: CHANGELOG "Convention going forward" (one entry per version bump matching `@version` and git tag/Hex release); "third CalVer component carries contract changes" |
| beam4pm | 26.10.1 | `mix.exs` L11 `version: "26.10.1"` | `## [Unreleased]` then `## [26.10.1] - 2026-10-01` | v26.9.10, v26.9.9 | yes | none in CONTRIBUTING (present but no versioning section) |
| ggen-marketplace | 26.9.12 | `marketplace.active.toml` L2 `version = "26.9.12"` (no mix.exs) | (no CHANGELOG.md) | v26.9.14, v26.9.24, v26.9.28, v26.9.29, v26.9.30 | yes | CONTRIBUTING.md L21: "versions use SemVer" — DIRECT CONTRADICTION with ecosystem CalVer practice |

## Findings

1. **ggen-marketplace CONTRIBUTING.md L21 explicitly says "versions use SemVer"** — the
   only repo with a wrong-family policy statement. Its actual tags are CalVer (v26.9.30
   latest). Needs rewrite to CalVer.
2. **ggen_igniter has the only fully explicit, machine-checked CalVer policy**
   (CONTRIBUTING.md + `mix ggen_igniter.doctor` enforcement of version==CHANGELOG-head
   match). This is the model policy; others should copy its shape.
3. **ggen_igniter 26.9.30-in-October is per stated policy, not drift**: the CHANGELOG
   says "`version:` stays 26.9.30 until release", with an unreleased v26.9.31 heading
   accumulating changes. Version stays until release day. Consistent.
4. **ash_pplan 26.10.1 vs 26.10.2-in-prep**: mix.exs is 26.10.1, CHANGELOG head is
   26.10.1 (released today 2026-10-01). No 26.10.2 heading exists yet — the "26.10.2-in-prep"
   mentioned in the lane brief is not yet materialized anywhere in the repo. UNKNOWN, not drift.
5. **ash_ex4pm (26.10.2) is ahead of its exact-pinned ex4pm (26.10.1)** — the `==` pin
   means they release in lockstep, but ash_ex4pm has already bumped to 26.10.2 while
   ex4pm 26.10.2 is not published. Currently a split within the lockstep pair; ash_ex4pm
   CHANGELOG documents this ("exact published ex4pm 26.10.1 pin..."), so it is documented,
   not silent. Resolves when ex4pm publishes 26.10.2.
6. **ash_pplan has zero git tags** despite a released 26.10.1 (publish-dry-run and
   release-verify receipts exist in `receipts/`). No tag = no replay anchor at v26.10.1.
7. **Tag formats differ**: ggen_igniter uses non-zero-padded months (v26.9.x); others mix
   `v26.10.1` style. All parse as vYY.M.P; zero-padding is a presentation inconsistency only.
8. **beam4pm/ash_ex4pm/ex4pm have Unreleased CHANGELOG heads already accumulating** —
   consistent with the ggen_igniter pattern (bump CHANGELOG first, mix.exs stays until release).
   ash_ex4pm deviates: it bumped `mix.exs` to 26.10.2 *before* release (see finding 5).

## Recommended uniform policy (per repo)

**CalVer `vYY.MM.P` (zero-padded MM); tag `vYY.MM.P` on the release commit; CHANGELOG
gains the next-version heading as `(unreleased)` immediately after a release;
`mix.exs version:` bumps only on release day; publish = tag + Hex push in one transition.**

- **ash_pplan**: adopt verbatim. Additionally: create the missing `v26.10.1` tag
  (first CalVer tag for the repo).
- **ggen_igniter**: already compliant; restate as `vYY.MM.P` zero-padded to match
  ecosystem format. Doctor check is the reference enforcement.
- **ash_ex4pm**: adopt verbatim; revert the premature `mix.exs` 26.10.2 bump to
  match ex4pm lockstep, or publish ex4pm 26.10.2 same-day (lockstep rule).
- **ex4pm**: adopt verbatim. Replace its "Convention going forward" CHANGELOG note
  with the uniform statement; keep third-component = contract-change rule.
- **beam4pm**: adopt verbatim; add the section to the existing CONTRIBUTING.md.
- **ggen-marketplace**: adopt verbatim **and delete the "versions use SemVer" sentence**
  in CONTRIBUTING.md L21 (wrong family); CHANGELOG.md absent — add one seeded from tags.

## Verification commands (replay)

```
grep -n "@version\|version:" ~/<repo>/mix.exs | head -3
head -8 ~/<repo>/CHANGELOG.md
git -C ~/<repo> tag | tail -5
grep -n -i "calver\|version" ~/<repo>/CONTRIBUTING.md
```
