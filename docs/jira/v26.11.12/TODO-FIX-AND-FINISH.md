# TODO-FIX-AND-FINISH (ash_pplan)

Standing: UNVERIFIED

Source: `ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` R7, re-read where marked confirmed.

## Fix

- HIGH `lib/ash_pplan/standing.ex:330-335` `observed_consequence_correct` fails only on literal
  `false`; empty checks give `:ok` (confirmed). Check: empty-consequence run is not `:alive`.
- HIGH `standing.ex:265-266` `wrong_provider?` passes when provider is nil (confirmed; fails
  open). Check: nil-provider event yields `provider_not_selected`.
- MED `standing.ex:458` `events != [] and Chain.verify(chain)` (confirmed; tautology claim
  UNVERIFIED). Check: tampered chain test flips standing.
- MED `standing.ex:300` gate-skip passes FOND UNVERIFIED (line moved; gate logic near 296-302).
- MED `reactor/durable/store/wal.ex:670,679,706` `truncate_tail` on corrupt header (confirmed
  exists; non-atomic/silent UNVERIFIED). Check: corrupt-header WAL test reports typed error.
- MED atom minting `capability_pack.ex:83,90`, `workflow/project/hddl.ex:322` (confirmed
  `String.to_atom`; hddl.ex:339 UNVERIFIED). Check: no `String.to_atom` on input.
- MED silent engine fallback `htn.ex:598-650` UNVERIFIED (only fallback comment at 1352 seen).
- LOW dead 8-minute poll and self-comparing `op_of/1` in provider court tests UNVERIFIED.

## Finish

- Make `standing/1` (`standing.ex:75`) refuse vacuous evidence. Check: planted empty run court.
- Replace silent WAL truncation with typed recovery. Check: restart court on corrupt tail.

## Commit hygiene

- Working tree has many ` M` docs plus staged renames (docs/jira -> docs/archive), confirmed
  by `git status`. Check: coordinator commits explicit paths; `git status --short` clean.

## Decide

- Should `Standing.Cached` staleness and AGENTS.md symlink claim be fixed or retired (UNVERIFIED).

## Reuse

- `workflow/subject.ex:13,93-109` `verify_projection/3`; `execution_receipt.ex:260-275`
  `escape_literal/1`; `chicago/collaborators/mock_scan.ex:64-104` AST scanner (UNVERIFIED lines).

## See Also

- `ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` R7
