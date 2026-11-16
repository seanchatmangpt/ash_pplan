---
name: mirror-sim-mutation
description: Shim-court mutation protocol for ash_pplan: prove a court can flip using a scratch copy of lib, byte-exact restore, loud skips.
---

# mirror-sim-mutation

BASELINE sha256 -> BEFORE (court green) -> SHIM (marked SHIM-COURT, scratch copy only) -> AFTER
(court must go red) -> RESTORE (sha256 byte-exact, fail-closed). A court that cannot flip is FAIL;
a skip prints `[SKIP] <reason>`. Self-check corrupts a restore on a temp copy to prove detection.
Never mutate the canonical `lib/` in place.
