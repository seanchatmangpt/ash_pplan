# Dep Pin Consistency Receipt — ex4pm / ash_ex4pm / beam4pm / ash_pplan

- Date: 2026-10-01
- Lane: P7 (read-only audit; no git mutations, no mix.exs edits executed)
- Subjects: ~/ash_pplan @ db06dc8, ~/beam4pm @ a81c3d37, ~/ash_ex4pm @ 1621d21, ~/ex4pm @ 2974b2a (tag v26.10.1)
- Hex ground truth (mix hex.info): ash_ex4pm 26.10.2 NOT published; hex has 26.10.1.

## Pin graph (observed 2026-10-01)

| repo | dep | mix.exs declaration | resolved (mix.lock) | status |
|---|---|---|---|---|
| ex4pm 26.10.1 | — | — | — | source of truth; released v26.10.1 |
| ash_ex4pm 26.10.2 (repo HEAD, unpublished) | ex4pm | `{:ex4pm, "== 26.10.1"}` | ex4pm 26.10.1 (hex) | exact pin, correct |
| ash_ex4pm 26.10.2 | ggen_igniter | `~> 26.9` (dev/test) | 26.9.9 | behind ex4pm's 26.9.29, cosmetic |
| beam4pm 26.10.1 | ash_ex4pm | `{:ash_ex4pm, "~> 26.10"}` (hex, no path override — the old `path: "../ash_ex4pm"` dev override is already gone) | ash_ex4pm **26.10.1** (hex) | current; will auto-pick 26.10.2 on next `mix deps.update` |
| beam4pm 26.10.1 | ex4pm | (transitive via ash_ex4pm) | ex4pm 26.10.1 (hex) | consistent |
| beam4pm 26.10.1 | ggen_igniter | `~> 26.9` (runtime: false) | 26.9.15 | fine |
| ash_pplan 26.10.1 | ex4pm | `{:ex4pm, "== 26.9.30", only: [:dev, :test], override: true}` | ex4pm **26.9.30** (hex) | STALE — two minors behind |
| ash_pplan 26.10.1 | ash_ex4pm | git ref `735ab7c3` (github, only: [:dev, :test]) | 735ab7c3... | STALE — predates hex 26.10.1 |
| ash_pplan 26.1pplan | ggen_igniter | git ref `0abed8a3` | 0abed8a3... | pinned ref, current for this lane |

## Consistency findings

1. **beam4pm is clean.** The dev path override noted in the task context is already
   reverted on main (a81c3d37): `{:ash_ex4pm, "~> 26.10"}` hex, lock at 26.10.1.
   No edit needed now; re-run `mix deps.update ash_ex4pm` after the 26.10.2 publish.
2. **ash_pplan is the stale outlier** (two problems):
   - `ex4pm == 26.9.30` with `override: true` — the comment ("ash_ex4pm still
     declares ex4pm 26.9.9, hence override") is doubly stale: ash_ex4pm now
     declares `== 26.10.1`, so the override forces ex4pm 26.9.30 over ash_ex4pm's
     `== 26.10.1` contract pin. In a fresh `mix deps.get`, override wins and
     ash_pplan runs ash_ex4pm code against a contract version it explicitly
     refuses.
   - ash_ex4pm pinned to git 735ab7c3 when hex 26.10.1 exists.
3. **ash_ex4pm's own pins are correct**: `== 26.10.1` matches its lock and its
   released contract. Keep unchanged.
4. **If ex4pm 26.10.2 ships**: ash_ex4pm's `== 26.10.1` means every consumer of
   ash_ex4pm is hard-frozen at ex4pm 26.10.1 until a new ash_ex4pm release bumps
   the pin (its own comment states this policy). beam4pm `~> 26.10` on ash_ex4pm
   picks it up on update; ash_pplan's git pin would NOT pick it up at all (fixed
   ref), another reason to move to hex.

## Target state + exact edits (checklist for post-publish lane — NOT executed)

### ash_pplan (~/ash_pplan/mix.exs, lines 55-59)
- [ ] Delete the stale comment at line 55.
- [ ] Replace line 56 with `{:ex4pm, "~> 26.10"}` (drop `== 26.9.30` and
      `override: true` — no longer needed once ash_ex4pm comes from hex).
- [ ] Replace lines 57-60 with `{:ash_ex4pm, "~> 26.10", only: [:dev, :test]}`.
- [ ] Run `mix deps.update ash_ex4pm ex4pm ggen_igniter` (optionally also move
      ggen_igniter to hex `~> 26.9` while touching this block), commit lock.
- [ ] Falsifier: fresh `mix deps.get` resolves ash_ex4pm 26.10.x with
      `ex4pm == 26.10.1` and no override conflicts.

### beam4pm (~/beam4pm/mix.exs, line 88)
- [ ] No mix.exs edit (already `~> 26.10` hex). Post-publish only:
- [ ] `mix deps.update ash_ex4pm` after ash_ex4pm 26.10.2 hits hex.
- [ ] Falsifier: lock shows ash_ex4pm 26.10.2 with ex4pm 26.10.1.

### ash_ex4pm (~/ash_ex4pm/mix.exs, line 52)
- [ ] No change now: keep `{:ex4pm, "== 26.10.1"}` until ex4pm 26.10.2 actually
      ships. When ex4pm bumps: bump to `== 26.10.2`, cut ash_ex4pm 26.10.3,
      publish, then consumers update.

## Verification commands

```
mix hex.info ash_ex4pm 26.10.2   # => "No release with name ash_ex4pm 26.10.2" (as of 2026-10-01)
grep -n 'ex4pm' ~/ash_pplan/mix.exs
grep -n 'ash_ex4pm' ~/beam4pm/mix.exs
```
