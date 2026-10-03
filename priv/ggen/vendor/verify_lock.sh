#!/usr/bin/env bash
# Read-only check: every vendored file's sha256 must still match
# priv/ggen/vendor/PACKS.lock.json. Run any time; run inside bin/tokyo-ggen-sync
# before rendering. Mirrors ex4pm's `mix ex4pm.ggen.verify_determinism` gate.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$here" <<'PY'
import hashlib, json, os, sys
here = sys.argv[1]
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
print("verify_lock: OK (%d packs, lock %s)" % (
    len(lock["packs"]), lock["source_git_sha"]))
PY
