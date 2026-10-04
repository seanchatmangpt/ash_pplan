// Golden-vector driver (bun). Usage: bun driver.ts <golden.vec>; imports generated src/es/chain.ts.
import { readFileSync } from "node:fs";
import { appendPending, appendOutcome, seal, unpaired, verify, digest, canonical, GENESIS, type Chain, type Entry } from "./src/es/chain.ts";

let chain: Chain = [];
for (const raw of readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!raw || raw.startsWith("#")) continue;
  const p = raw.split("|");
  if (raw.startsWith("case ")) { chain = []; console.log("case", raw.slice(5)); }
  else if (p[0] === "pending" || p[0] === "outcome" || p[0] === "seal") {
    try {
      const e = p[0] === "pending" ? appendPending(chain, p[1], p[2], p[3]) : p[0] === "outcome" ? appendOutcome(chain, p[1], p[2], p[3], p[4]) : seal(chain, p[1], p[2], p[3]);
      console.log("ok", e.hash);
    } catch { console.log("err"); }
  } else if (p[0] === "forge") {
    const i = Number(p[6]);
    const e: Entry = { entry_id: p[1], parent_hash: chain.length ? chain[chain.length - 1].hash : GENESIS, phase: p[2], standing: p[3], subject: p[4], action: p[5], pending_ref: i >= 0 ? chain[i].hash : "", hash: "" };
    e.hash = digest(canonical(e as unknown as Record<string, unknown>));
    chain.push(e);
    console.log("ok", e.hash);
  } else if (p[0] === "unpaired") console.log("unpaired", unpaired(chain).join(","));
  else if (p[0] === "verify") console.log("verify", verify(chain) ? "true" : "false");
  else if (p[0] === "tamper") { chain[0].subject = "tampered"; console.log("tampered"); }
}
