# Gate Receipt: Vendor Lock Re-Witness — 2026-10-04

- subject: /Users/sac/ash_pplan priv/ggen/vendor (canonical checkout, main @ 9a89aac + working tree)
- purpose: re-witness vendor lock determinism after protocol-court lane rewrote sync.sh and vendored ash-pplan-protocol-court-pack
- write scope: this receipt only (READ-MOSTLY lane); no vendor/source files modified this run

## Determinism (double-run of sync.sh)

| file | sha256 before | sha256 after | identical |
|---|---|---|---|
| priv/ggen/vendor/PACKS.lock.json | e5f27d8c3fea2aafe0e37b2f6057e70664bba127a6d70700672f935bb9774f40 | e5f27d8c3fea2aafe0e37b2f6057e70664bba127a6d70700672f935bb9774f40 | YES |
| priv/ggen/vendor/provenance.ttl | f715e2dc920172612e75302917d0f2b28fd1434ede0846dfe98f7551b441cf5a | f715e2dc920172612e75302917d0f2b28fd1434ede0846dfe98f7551b441cf5a | YES |

**Verdict: DETERMINISTIC** — sync.sh (RTI_ALLOW_MOVED_MARKETPLACE=1) is byte-idempotent on both lock outputs.

## sync.sh output (exit 0)

```
sync.sh: vendored tokyo-depeg-burn-in-pack ash-pplan-protocol-court-pack (sha256-locked) + ash-runtime-integration-contract-pack overlay (64 files, 9 patched)
sync.sh: vendored tokyo-depeg-burn-in-pack ash-pplan-protocol-court-pack + ash-runtime-integration-contract-pack overlay from /Users/sac/ggen-marketplace (sha256-locked at 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
```

Marketplace HEAD move already accepted today (env var honored as instructed); lock identity `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2`.

## verify_lock.sh

```
verify_lock: OK (3 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
```
exit 0.

## git diff --stat (vs HEAD — pre-existing lane churn, NOT this double-run)

```
 priv/ggen/vendor/PACKS.lock.json                   | 650 ++++++++++++++++++++-
 priv/ggen/vendor/provenance.ttl                    |  35 +-
 priv/ggen/vendor/sync.sh                           | 343 ++++++++++-
 .../ggen/vendor/tokyo-depeg-burn-in-pack/pack.toml |   7 +-
 priv/ggen/vendor/verify_lock.sh                    |   5 +-
 5 files changed, 1008 insertions(+), 32 deletions(-)
```

This diff vs HEAD is today's already-admitted protocol-court lane churn (sync.sh rewrite + new pack). The zero-byte-change claim for THIS double-run rests on sha256 identity above (git has no second state to diff against).

## Standing

ALIVE — lock determinism witnessed on exact subject; verify_lock CONFORMANT; no changes introduced by this gate run.
