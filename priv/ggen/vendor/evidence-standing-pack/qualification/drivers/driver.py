"""Golden-vector driver (python). Usage: python3 driver.py <golden.vec>; imports generated src/es/chain.py."""
import sys
sys.path.insert(0, "src/es")
import chain as C

chain = []
for raw in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if not raw or raw.startswith("#"):
        continue
    p = raw.split("|")
    if raw.startswith("case "):
        chain = []
        print("case", raw[5:])
    elif p[0] in ("pending", "outcome", "seal"):
        try:
            fn = {"pending": C.append_pending, "outcome": C.append_outcome, "seal": C.seal}[p[0]]
            print("ok", fn(chain, *p[1:])["hash"])
        except ValueError:
            print("err")
    elif p[0] == "forge":  # bypasses the append API: a hostile writer that rehashes correctly
        e = {"entry_id": p[1], "parent_hash": chain[-1]["hash"] if chain else C.GENESIS, "phase": p[2],
             "standing": p[3], "subject": p[4], "action": p[5], "pending_ref": chain[int(p[6])]["hash"] if int(p[6]) >= 0 else ""}
        e["hash"] = C.digest(C.canonical(e))
        chain.append(e)
        print("ok", e["hash"])
    elif p[0] == "unpaired":
        print("unpaired", ",".join(C.unpaired(chain)))
    elif p[0] == "verify":
        print("verify", "true" if C.verify(chain) else "false")
    elif p[0] == "tamper":
        chain[0]["subject"] = "tampered"
        print("tampered")
