#!/usr/bin/env bash
# Read-only check: every vendored file's sha256 must still match
# priv/ggen/vendor/PACKS.lock.json. Run any time; run inside
# test/support/tokyo_depeg/tokyo-ggen-sync before rendering. Mirrors ex4pm's
# `mix ex4pm.ggen.verify_determinism` gate.
#
# ERRC-R4 extension: beyond lock self-consistency, also checks the lock's
# `source_git_sha` against the marketplace repo:
#   1. HARD FAIL if the pinned sha does not exist in the marketplace repo
#      (the lock then references an un-checkoutable subject).
#   2. LOUD WARN (exit 0 by default; VERIFY_LOCK_STRICT=1 escalates to a
#      hard fail) if marketplace HEAD != pin. sync.sh's pin gate already
#      refuses un-acknowledged pin moves, so this only surfaces drift
#      between syncs, it does not police it.
# Marketplace repo: $GGEN_MARKETPLACE_DIR (default ~/ggen-marketplace).
# Testing override: VERIFY_LOCK_SIMULATED_HEAD=<sha> substitutes the observed
# HEAD (read-only, test-only) so the HEAD-moved warn branch is exercisable
# without writing to the marketplace repo.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
market="${GGEN_MARKETPLACE_DIR:-$HOME/ggen-marketplace}"
python3 - "$here" "$market" <<'PY'
import hashlib, json, os, subprocess, sys
here, market = sys.argv[1], sys.argv[2]
lock = json.load(open(os.path.join(here, "PACKS.lock.json")))
bad = []
for pack in lock["packs"] + lock["generated"]:
    for f in pack["files"] if "files" in pack else pack and []:
        pass
for pack in lock["packs"]:
    for f in pack["files"]:
        p = os.path.join(here, f["path"])
        if not os.path.exists(p):
            bad.append((f["path"], "missing"))
        else:
            got = hashlib.sha256(open(p, "rb").read()).hexdigest()
            if got != f["sha256"]:
                bad.append((f["path"], f"sha256 {got} != {f['sha256']}"))
for f in lock["generated"]:
    p = os.path.join(here, f["path"])
    got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if got != f["sha256"]:
        bad.append((f["path"], f"sha256 {got} != {f['sha256']}"))
if bad:
    for path, why in bad:
        print(f"verify_lock: MISMATCH {path}: {why}", file=sys.stderr)
    sys.exit(1)

# --- ERRC-R4: upstream@pin checks -------------------------------------------
pin = lock.get("source_git_sha")
if not pin:
    print("verify_lock: FAIL lock has no source_git_sha", file=sys.stderr)
    sys.exit(1)
if not os.path.isdir(os.path.join(market, ".git")):
    print(f"verify_lock: FAIL marketplace repo not found at {market}", file=sys.stderr)
    sys.exit(1)

def git(*args):
    return subprocess.run(["git", "-C", market, *args], capture_output=True, text=True)

r = git("cat-file", "-e", f"{pin}^{{commit}}")
if r.returncode != 0:
    print(f"verify_lock: FAIL pinned source_git_sha {pin} does not exist in "
          f"{market} (lock references an un-checkoutable subject)", file=sys.stderr)
    sys.exit(1)

head = os.environ.get("VERIFY_LOCK_SIMULATED_HEAD") or git("rev-parse", "HEAD").stdout.strip()
if head != pin:
    strict = os.environ.get("VERIFY_LOCK_STRICT", "0") == "1"
    print(f"verify_lock: WARN marketplace HEAD {head} != pinned {pin}; "
          f"vendored bytes were synced at the pin. Re-run priv/ggen/vendor/sync.sh to re-pin, "
          f"or set VERIFY_LOCK_STRICT=1 to make this a failure.", file=sys.stderr)
    if strict:
        sys.exit(1)

print("verify_lock: OK (%d packs, lock %s)" % (
    len(lock["packs"]), pin))
PY
