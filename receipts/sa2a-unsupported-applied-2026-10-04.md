# Receipt: sa2a pack family marked UNSUPPORTED in composition-space.ttl (D1 / Option A)

Date: 2026-10-04. Executes `docs/jira/ECO-SA2A-EXECUTION.md` exactly as written.

## Action

Appended the 23-triple patch block (primitives U/V/W, `cmd:standing
"UNSUPPORTED"`, with `rdfs:seeAlso` evidence IRIs) to
`~/.claude/dfcm/composition-space.ttl`, after the `dfcm:C24` block and before
the trailing `# hook-probe` comment line. Additions only; no existing line
touched. Ids U/V/W verified unused immediately before applying (existing ids
end at T).

## Identity

- Canonical TTL before: sha256 `37b1201fce7cafd2f45ce84adb447b20ac225392b43cf92c580f6a70c683e5dc`
- Canonical TTL after: sha256 `ba584cd0cc51bdfc8b5bc2fb104aa893c10c7dac26aa8d7ed75f9ef28d095abb`
- Backup (reversal anchor): `~/.claude/dfcm/composition-space.ttl.bak-sa2a-20261004`
  (= pre-patch file, sha `37b1201fce7cafd2...`)

## Consequence (projection output, real)

- `python3 ~/.claude/dfcm/project.py`
  → `ADMITTED primitives=23 compositions=24 -> /Users/sac/.claude/rules/dfcm-composition-catalog.md`
  (baseline pre-patch: 20 primitives, 24 compositions; zero refusals)
- `python3 ~/.claude/dfcm/project.py --check` → `IN_SYNC`, exit 0
- Projected catalog delta, verified by grep on
  `/Users/sac/.claude/rules/dfcm-composition-catalog.md` lines 32-34: three
  new UNSUPPORTED rows U/V/W appended to the Primitives table; Compositions
  table unchanged (count stays 24; no candidate selects U/V/W).
- Projected catalog sha256 after: `38c2df58b571337a54aaa76959fc92773bb5a24b271d8ede0838e4df0d807e0d`;
  digest line now cites source sha `ba584cd0cc51bdfc` (was `37b1201fce7cafd2`).

## Replay

```
shasum -a 256 ~/.claude/dfcm/composition-space.ttl          # ba584cd0...95abb
python3 ~/.claude/dfcm/project.py --check                    # IN_SYNC, exit 0
grep -c 'UNSUPPORTED' ~/.claude/rules/dfcm-composition-catalog.md  # 4 (Q + U,V,W)
```

## Reversal

`cp ~/.claude/dfcm/composition-space.ttl.bak-sa2a-20261004 ~/.claude/dfcm/composition-space.ttl`
then re-run `python3 ~/.claude/dfcm/project.py` and `--check` (expect
primitives=20, IN_SYNC). Or delete the appended block (from
`# --- 2026-10-04 sa2a pack family marked UNSUPPORTED` through the `dfcm:W`
statement, plus its rdfs:seeAlso lines) — see ECO-SA2A-EXECUTION.md section 4.
Idents U/V/W: prefer retiring the letters permanently on reversal.

## Standing

Applied on the one canonical checkout's owned files only (composition-space.ttl
+ projection + this receipt). No other files touched, no git operations.
