#!/usr/bin/env bash
# Re-vendor the marketplace packs ash_pplan consumes (W2 of the tokyo-depeg
# plan) and rewrite PACKS.lock.json + provenance.ttl deterministically (no
# timestamps): same pack bytes + same source git sha => byte-identical lock.
# Mirrors ~/ex4pm/priv/ggen/vendor/sync.sh (the proven file-level pattern),
# extended to also vendor templates/*.eex because ash_pplan renders the pack
# through test/support/tokyo_depeg/tokyo-ggen-sync against the vendored
# ontology + gates (the driver was relocated out of bin/; this script and that
# driver are the only entry points into the vendored flow).
#
#   priv/ggen/vendor/sync.sh [path-to-ggen-marketplace]   # default ~/ggen-marketplace
#
# ECO-SAGA-COMPENSATE extension: also vendors the runtime-integration pack
# (ash-runtime-integration-contract-pack @ the pinned marketplace sha) into
# the consumer overlay priv/ggen/ash-pplan-runtime-overlay/ — templates/,
# gates/, queries/ — and records the overlay files in the same lock. The
# overlay's ontology.ttl is consumer-authored (NOT vendored, NOT locked): it
# carries the rt:SagaCompensation individuals moved out of the pack and the
# consumer rt:Integration row. Three deterministic consumer patches are
# applied to the vendored copies (each marked `patched: true` in the lock):
#   1. templates/durable_saga_compensation.ex.eex — the hardcoded consumer
#      alias line becomes the `rt:durableAliases` binding (draft 2.4).
#   2. gates/140-saga-compensation.rq — the saga driver query selects
#      ?durable_aliases so the template binding resolves.
#   3. the five .ex.tmpl surfaces — the pack ships Tera (`{{ x }}`) while the
#      consumer's only generator (ggen_igniter Render) is EEx-only; the
#      mechanical Tera->EEx projection happens here, at vendor time, so the
#      overlay stays generatable from the pinned pack bytes.
#
# ECO-PROTOCOL-COURT extension: ash-pplan-protocol-court-pack (the generalized
# TLA+/TLC/Stateright differential protocol-court pack, 0.1.0) is vendored
# whole alongside tokyo-depeg (ontology + pack.toml + gates + templates +
# verify/), sha256-locked the same way, so its four rendered surfaces
# (priv/ggen/generated/protocol-court/ via bin/manufacture-protocol-court)
# regenerate from pinned bytes.
#
# Read-only lock check: priv/ggen/vendor/verify_lock.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
market="${1:-$HOME/ggen-marketplace}"
# ERRC C3/C4/C5 additions (2026-10-04): workflow-corpus-pack (adversarial
# workflow fixtures), ash-pplan-chaos-pack (generalized chaos suites),
# state-transition-pack + evidence-standing-pack (refusal-gate packs).
packs=(tokyo-depeg-burn-in-pack ash-pplan-protocol-court-pack semantic-gate-witness-court-pack ash-extension-core-pack workflow-corpus-pack ash-pplan-chaos-pack state-transition-pack evidence-standing-pack)

# --- runtime-integration pack (ECO-SAGA-COMPENSATE adoption) ---------------
rt_pack="ash-runtime-integration-contract-pack"
rt_src="$market/packs/$rt_pack"
rt_overlay="$here/../ash-pplan-runtime-overlay"
# Re-pin receipt 2026-10-04: the marketplace moved 5214eb0e -> 503af6c2 while
# this adoption was in flight (witnessed by this script's own pin gate
# refusing); the pack's vendored surfaces are byte-identical across the move
# (Tera templates unchanged, saga residue still present, gate 04 still
# unwired), so the pin moves with the lock, not the bytes.
#
# Re-pin receipt 2026-10-05 (ERRC-P): the marketplace moved 503af6c2 ->
# 6f779318 (8 commits: aaif-vanilla-pack + architecture docs). Of the vendored
# packs only ash-extension-core-pack and tokyo-depeg-burn-in-pack changed, and
# both changes are pure file additions (1382 insertions, 0 deletions across
# the 503af6c2..6f779318 diff of packs/), so again the pin moves with the
# lock, not the bytes. Witnessed by sync.sh's own pin gate refusing.
# Re-pin receipt 2026-10-07 (W984hd): the marketplace moved 6f779318 ->
# ba21c22a (fast-forward; 6f779318 is a git merge-base ancestor of HEAD on
# feat/aaif-gcp-roadmap-v26.10.5). Unlike the 2026-10-05 move, the vendored
# pack BYTES also changed this time (gates reworked across ash-pplan-chaos /
# protocol-court / state-transition / evidence-standing; tokyo-depeg gates +
# templates .eex -> .tmpl renames), so this re-pin is a real re-vendor at the
# new pin, not a lock-only move. Witnessed by sync.sh's own pin gate refusing.
# Re-pin receipt 2026-10-08 (lane pplan-repin): marketplace moved ba21c22a ->
# 29c579082aefe57eda5695d13cd4edb76cb82b31 on feat/aaif-gcp-roadmap-v26.10.5
# (v26.10.8 bump; fast-forward, ba21c22a is a merge-base ancestor of HEAD).
# Witnessed by sync.sh's own pin gate refusing.
rt_expected_sha="29c579082aefe57eda5695d13cd4edb76cb82b31"

[ -d "$market/packs" ] || { echo "sync.sh: no packs dir at $market" >&2; exit 2; }

# Pin gate (draft open-risk: "a silent 5214eb0e..HEAD move on the marketplace
# side is invisible to the sync itself" — make it loud instead). The lock
# always records the real HEAD; the refusal only forces the move to be seen.
head_sha="$(git -C "$market" rev-parse HEAD)"
if [ "$head_sha" != "$rt_expected_sha" ] && [ "${RTI_ALLOW_MOVED_MARKETPLACE:-0}" != "1" ]; then
  echo "sync.sh: marketplace HEAD $head_sha != pinned $rt_expected_sha" >&2
  echo "sync.sh: refusing; re-pin rt_expected_sha (or set RTI_ALLOW_MOVED_MARKETPLACE=1)" >&2
  exit 3
fi

for p in "${packs[@]}"; do
  src="$market/packs/$p"
  [ -f "$src/ontology.ttl" ] || { echo "sync.sh: missing $src/ontology.ttl (W1 pack); run W1 first" >&2; exit 2; }
  rm -rf "$here/$p"
  mkdir -p "$here/$p/gates" "$here/$p/templates"
  cp "$src/ontology.ttl" "$here/$p/ontology.ttl"
  cp "$src/pack.toml" "$here/$p/pack.toml"
  for g in "$src"/gates/*.rq; do [ -e "$g" ] && cp "$g" "$here/$p/gates/"; done
  # ERRC C4/C5: packs shipping .py gates (template literal scans) and Tera
  # templates (.tmpl) -- vendor those too.
  for g in "$src"/gates/*.py; do [ -e "$g" ] && cp "$g" "$here/$p/gates/"; done
  for t in "$src"/templates/*.eex; do [ -e "$t" ] && cp "$t" "$here/$p/templates/"; done
  for t in "$src"/templates/*.tmpl; do [ -e "$t" ] && cp "$t" "$here/$p/templates/"; done
  # FM-PACK-005 re-add hook: ggen enforces a templates/*.tmpl floor per pack.
  # The marketplace sources predate that law, so a resync at the pinned SHAs
  # rm -rf's the vendored copy and would drop the placeholder. Re-add the
  # inert placeholder -- but ONLY when the marketplace pack ships no *.tmpl of
  # its own (an upstream placeholder must win over ours).
  if ! compgen -G "$src/templates/*.tmpl" >/dev/null; then
    cat > "$here/$p/templates/placeholder.tmpl" <<'PLACEHOLDER_TMPL'
---
to: "tmp/ggen-law-placeholder.txt"
mode: file
---
placeholder template satisfying ggen FM-PACK-005 (templates/*.tmpl floor); renders to tmp/ only.
PLACEHOLDER_TMPL
  fi
  # ERRC C3: workflow-corpus ships a witness-court contract (gate-court.toml)
  # plus fixtures/, witnesses/, qualification/ trees -- vendored whole.
  [ -f "$src/gate-court.toml" ] && cp "$src/gate-court.toml" "$here/$p/gate-court.toml"
  for d in fixtures witnesses qualification; do
    [ -d "$src/$d" ] && cp -R "$src/$d" "$here/$p/$d"
  done
  # ECO-SEMANTIC-GATE-WITNESS extension: also vendor Tera court/runner
  # templates (.py.tera), the court's contract queries (queries/*.rq) and its
  # contract test (tests/) when the pack ships them.
  for t in "$src"/templates/*.py.tera; do [ -e "$t" ] && cp "$t" "$here/$p/templates/"; done
  if [ -d "$src/queries" ]; then
    mkdir -p "$here/$p/queries"
    for q in "$src"/queries/*.rq; do [ -e "$q" ] && cp "$q" "$here/$p/queries/"; done
  fi
  if [ -d "$src/tests" ]; then
    mkdir -p "$here/$p/tests"
    for u in "$src"/tests/*; do [ -e "$u" ] && cp "$u" "$here/$p/tests/"; done
  fi
  # Fail-closed verification surface (verify/*.unbound.rq + cardinality.json),
  # vendored when the pack ships one so ggen-verify can run against the
  # vendored copy without reaching into the marketplace tree.
  if [ -d "$src/verify" ]; then
    mkdir -p "$here/$p/verify"
    for v in "$src"/verify/*; do cp "$v" "$here/$p/verify/"; done
  fi
done

# --- runtime-integration pack: copy + patch into the overlay ---------------
[ -f "$rt_src/ontology.ttl" ] || { echo "sync.sh: missing $rt_src/ontology.ttl" >&2; exit 2; }
[ -f "$rt_src/ggen.toml" ] || { echo "sync.sh: missing $rt_src/ggen.toml" >&2; exit 2; }
mkdir -p "$rt_overlay"

python3 - "$here" "$market" "$rt_pack" "$rt_src" "$rt_overlay" "${packs[@]}" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys

here, market, rt_pack, rt_src, rt_overlay = sys.argv[1:6]
vendored_packs = sys.argv[6:]

# ---- ECO-ASHEXT-ADDITION deterministic consumer patch -----------------------
# The pack template's raw output is NOT mix-format-stable (2 leading blank
# lines from the front-matter/comment boundary, ops list rendered one-line
# where the formatter wraps it) and carries no GENERATED marker. Left raw,
# every sync's bytes differ from the formatted disk state and
# bin/ggen-replay-court --dry-run-preview reports permanent phantom drift.
# Patched at vendor time (same disclosed pattern as the runtime-overlay
# patches below): (a) emit the repo GENERATED-marker convention
# (lib/ash_pplan/dsl.ex) at output top; (b) render `def ops` in the exact
# multi-line shape the formatter produces. Marked patched in the lock.
aext_tpl = os.path.join(here, "ash-extension-core-pack", "templates",
                        "ash_reactor_extended_adapter.ex.eex")
aext_t = open(aext_tpl).read()
_aext_header = (
    '<%= "# GENERATED by ggen_igniter from ash-extension-core-pack '
    'ontology.ttl (aex:AshPPlanAshReactorExtended)." %>\n'
    '<%= "# Do not edit. Regenerate with ./bin/manufacture." %>\n'
)
_ops_one = '  def ops, do: <%= inspect(Enum.map(ops, fn op -> String.to_atom(op["op_name"]) end)) %>'
_ops_multi = (
    "  def ops,\n"
    "    do: [\n"
    '<%= Enum.map_join(ops, ",\\n", fn op -> "      :" <> op["op_name"] end) %>\n'
    "    ]"
)
_fm_split = aext_t.split("---\n", 2)
if len(_fm_split) != 3:
    sys.exit("sync.sh: aext template front matter not found to patch")
_body = _fm_split[2]
if _ops_one in _body:
    _body = _body.replace(_ops_one, _ops_multi)
elif ":bulk_destroy\n    ]" not in _body:
    sys.exit("sync.sh: aext template ops line not found to patch")
if "_aext_header" not in _body and 'GENERATED by ggen_igniter from ash-extension-core-pack' not in _body:
    _body = _aext_header + _body
open(aext_tpl, "w").write("---\n".join([_fm_split[0], _fm_split[1], _body]))
aext_patched = os.path.join("ash-extension-core-pack", "templates",
                            "ash_reactor_extended_adapter.ex.eex")

def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

def git(*args):
    return subprocess.check_output(["git", "-C", market, *args], text=True).strip()

head = git("rev-parse", "HEAD")

# ---- 1. copy the vendored surfaces into the overlay ------------------------
for d in ("templates", "gates", "queries"):
    shutil.rmtree(os.path.join(rt_overlay, d), ignore_errors=True)
    os.makedirs(os.path.join(rt_overlay, d), exist_ok=True)

# queries: the projection range the pack's own ggen.toml drives, plus the saga
# driver (140) that the consumer --for-each recipe needs.
ggen_toml = open(os.path.join(rt_src, "ggen.toml")).read()
query_files = sorted(set(re.findall(r'file\s*=\s*"(queries/[^"]+\.rq)"', ggen_toml)))
query_files.append("queries/140-saga-compensation.rq")
for rel in sorted(set(query_files)):
    shutil.copy(os.path.join(rt_src, rel), os.path.join(rt_overlay, rel))

# gates: all four pack gates + the saga driver (ggen_igniter discovers pack
# queries from gates/*.rq, so the --for-each driver must live there too).
for g in sorted(os.listdir(os.path.join(rt_src, "gates"))):
    if g.endswith(".rq"):
        shutil.copy(os.path.join(rt_src, "gates", g), os.path.join(rt_overlay, "gates", g))
shutil.copy(os.path.join(rt_src, "queries/140-saga-compensation.rq"),
            os.path.join(rt_overlay, "gates", "140-saga-compensation.rq"))

# templates: the saga template + the five phase-2 surfaces.
surfaces = ["durable_saga_compensation.ex.eex", "exact_subject.ex.tmpl",
            "authority_gate.ex.tmpl", "receipt.ex.tmpl", "replay.ex.tmpl",
            "refusal.ex.tmpl"]
for t in surfaces:
    shutil.copy(os.path.join(rt_src, "templates", t), os.path.join(rt_overlay, "templates", t))

# ---- 2. the three deterministic consumer patches ---------------------------
patched = []

# 2a. saga template: hardcoded consumer alias line -> rt:durableAliases binding.
p = os.path.join(rt_overlay, "templates/durable_saga_compensation.ex.eex")
t = open(p).read()
hard = "  alias AshPPlan.Reactor.Durable.{Clock, Store.Ets}\n"
param = "  alias <%= clean.(durable_aliases) %>\n"
if hard in t:
    t = t.replace(hard, param)
elif param not in t:
    sys.exit("sync.sh: saga template alias line not found to patch")
open(p, "w").write(t)
patched.append("templates/durable_saga_compensation.ex.eex")

# 2b. saga driver query: select ?durable_aliases too.
p = os.path.join(rt_overlay, "gates/140-saga-compensation.rq")
q = open(p).read()
q = q.replace(
    "SELECT ?seq_order ?compensation_module ?step_module ?step_label ?undo_prefix ?effect WHERE {",
    "SELECT ?seq_order ?compensation_module ?step_module ?step_label ?undo_prefix ?durable_aliases ?effect WHERE {")
q = q.replace(
    "    rt:undoPrefix ?undo_prefix ;\n    rt:effect ?effect .",
    "    rt:undoPrefix ?undo_prefix ;\n    rt:durableAliases ?durable_aliases ;\n    rt:effect ?effect .")
if "?durable_aliases" not in q.split("WHERE")[0]:
    sys.exit("sync.sh: saga driver query did not take the durable_aliases patch")
open(p, "w").write(q)
patched.append("gates/140-saga-compensation.rq")

# 2c. Tera -> EEx on the five phase-2 surfaces (ggen_igniter Render is EEx-only;
# the pack's .ex.tmpl are Tera for the Rust ggen). Mechanical projection, given
# the oxigraph engine's PLAIN value normalization (no quote/IRI wrappers):
#   {{ x | json_encode }} -> <%= inspect(x) %>   (re-quotes a plain string literal)
#   {{ x }}               -> <%= x %>            (module names, plain strings)
# The two surfaces whose pack template HARDCODES the generic module name
# (Ggen.RuntimeIntegration.*) get their defmodule line bound from the consumer
# row (rt:exactSubjectModule / rt:authorityGateModule), per draft 1.2 "module
# names chosen by consumer ontology rows".
defmodule_patches = {
    "exact_subject": (
        "defmodule Ggen.RuntimeIntegration.ExactSubject do",
        "defmodule <%= exact_subject_module %> do",
    ),
    "authority_gate": (
        "defmodule Ggen.RuntimeIntegration.AuthorityGate do",
        "defmodule <%= authority_gate_module %> do",
    ),
}
for stem in ("exact_subject", "authority_gate", "receipt", "replay", "refusal"):
    rel = f"templates/{stem}.ex.tmpl"
    p = os.path.join(rt_overlay, rel)
    body = open(p).read()
    header = (
        "# GENERATED-PROVENANCE: EEx projection of\n"
        f"#   packs/{rt_pack}/templates/{stem}.ex.tmpl (Tera) at marketplace pin\n"
        f"#   {head}, applied by\n"
        "#   priv/ggen/ash-pplan-runtime-overlay driver bin/manufacture-runtime-contract\n"
        "#   and priv/ggen/vendor/sync.sh. Editing this file by hand is a refused\n"
        "#   transition: edit the pack template upstream (and the consumer rows in\n"
        "#   the overlay ontology) and re-vendor + re-sync.\n"
    )
    body = re.sub(r"\{\{ (\w+) \| json_encode \}\}", r"<%= inspect(\1) %>", body)
    body = re.sub(r"\{\{ (\w+) \}\}", r"<%= \1 %>", body)
    if stem in defmodule_patches:
        hard, param = defmodule_patches[stem]
        if hard in body:
            body = body.replace(hard, param)
        elif param not in body:
            sys.exit(f"sync.sh: {rel} defmodule line not found to patch")
    open(p, "w").write(header + body)
    patched.append(rel)

# 2d. queries 01/02: bind the consumer module name from the overlay rows.
for rel, sel_old, sel_new, tri_old, tri_new in (
    (
        "queries/01-exact-subject.rq",
        "SELECT ?integration ?subject ?repo ?base ?head WHERE {",
        "SELECT ?integration ?exact_subject_module ?subject ?repo ?base ?head WHERE {",
        "  ?integration a rt:Integration ; rt:hasSubject ?subject .",
        "  ?integration a rt:Integration ; rt:hasSubject ?subject ;\n  rt:exactSubjectModule ?exact_subject_module .",
    ),
    (
        "queries/02-authority-policy.rq",
        "SELECT ?integration ?policy ?action WHERE {",
        "SELECT ?integration ?authority_gate_module ?policy ?action WHERE {",
        "  ?integration a rt:Integration ; rt:hasAuthorityPolicy ?policy .",
        "  ?integration a rt:Integration ; rt:hasAuthorityPolicy ?policy ;\n  rt:authorityGateModule ?authority_gate_module .",
    ),
):
    p = os.path.join(rt_overlay, rel)
    q = open(p).read()
    if sel_new in q and tri_new in q:
        pass  # already patched (idempotent re-run after partial failure)
    else:
        q = q.replace(sel_old, sel_new)
        q = q.replace(tri_old, tri_new)
        if sel_new not in q or tri_new not in q:
            sys.exit(f"sync.sh: {rel} did not take the consumer-module patch")
    open(p, "w").write(q)
    patched.append(rel)

# 2e. mirror the five phase-2 driver queries into gates/ (ggen_igniter
# discovers pack queries from gates/*.rq only, so a plain --pack-dir render —
# e.g. the regeneration court — binds the five surfaces' variables without
# explicit --query flags).
for rel in (
    "queries/01-exact-subject.rq",
    "queries/02-authority-policy.rq",
    "queries/06-receipt.rq",
    "queries/07-replay.rq",
    "queries/08-refusal.rq",
):
    shutil.copy(os.path.join(rt_overlay, rel), os.path.join(rt_overlay, "gates", os.path.basename(rel)))

# 2f. gate-hygiene consumer patch (ORDER BY determinism). The
# GgenGateHygieneTest court (test/ggen_gate_hygiene_test.exs, rule b) demands
# every ORDER BY run over a deterministic key: ORDER BY vars projected AND
# (SELECT DISTINCT OR a unique-key var in the projection). Marketplace gates
# with ORDER BY but no DISTINCT and no unique-key projection take the
# mechanical `SELECT` -> `SELECT DISTINCT` insert here, at vendor time, so the
# vendored copies satisfy the same law as consumer-authored gates.
# Deterministic: same rule, same bytes on every re-sync. Idempotent.
import re as _hy_re

# unique-key vars, matched at a word boundary (?s must not hit ?seq_order)
_HY_KEY_RE = _hy_re.compile(r"\?(s|subject|row|key|id)\b", _hy_re.I)


def _hygiene_patch(rel):
    p = os.path.join(here, rel)
    if not os.path.isfile(p):
        return
    t = open(p).read()
    if not _hy_re.search(r"ORDER\s+BY", t, _hy_re.I):
        return
    if _hy_re.search(r"SELECT\s+DISTINCT", t, _hy_re.I):
        return
    sel = _hy_re.search(r"SELECT\s+(.+?)\s*WHERE", t, _hy_re.S | _hy_re.I)
    if not sel:
        return
    if _HY_KEY_RE.search(sel.group(1)):
        return  # projection already carries a unique key var
    t = _hy_re.sub(r"\bSELECT\b", "SELECT DISTINCT", t, count=1)
    open(p, "w").write(t)
    patched.append(rel)


# ---- 2h. protocol-court positive drivers (W984im, 2026-10-07) ---------------
# Upstream ea8aff64b reworked the protocol pack's gates/*.rq into FILTER NOT
# EXISTS violation gates (0 rows on valid data -> zero-rows-is-pass offenders
# live in verify/ per GateVerify doctrine). Templates bind by gate stem
# (ggen_igniter build_bindings/2: `stem: rows` list bindings + single-row
# flattening), so a violation-shaped gate starves the renders: moduleName/
# cfgConstants/etc. assigns never materialize and the EEx compile refuses
# ("undefined variable cfgConstants"). Same bug class W984ic fixed upstream in
# ash-pplan-chaos-pack 2026-10-07. Consumer-side mechanical patch at vendor
# time, byte-identical to the pre-rework drivers (marketplace a224db049,
# base64-embedded so the bytes cannot drift in this file); the violation-gate
# bytes are preserved verbatim in verify/<stem>.violation.rq. Idempotent:
# violation copies are created only when missing; positive bytes are written
# every run; gate hygiene (2f) runs AFTER this patch so the restored drivers
# still pass the ORDER BY determinism law.
_PD = {
    "010_protocols":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9tb2R1bGVOYW1lID9tYWNoaW5lTGFiZWwgP3dvcmtlclNldCA/c3RlcFNldCA/dmFyaWFibGVzID93ZkFjdGlvbiA/aW5pdEV4cHIgP2NmZ0NvbnN0YW50cyBXSEVSRSB7CiAgP3AgYSBwY3A6UHJvdG9jb2wgOwogICAgIHBjcDptb2R1bGVOYW1lID9tb2R1bGVOYW1lIDsgcGNwOm1hY2hpbmVMYWJlbCA/bWFjaGluZUxhYmVsIDsKICAgICBwY3A6d29ya2VyU2V0ID93b3JrZXJTZXQgOyBwY3A6c3RlcFNldCA/c3RlcFNldCA7CiAgICAgcGNwOnZhcmlhYmxlcyA/dmFyaWFibGVzIDsgcGNwOndmQWN0aW9uID93ZkFjdGlvbiA7CiAgICAgcGNwOmluaXRFeHByID9pbml0RXhwciA7IHBjcDpjZmdDb25zdGFudHMgP2NmZ0NvbnN0YW50cyAuCn0KT1JERVIgQlkgP21vZHVsZU5hbWUK",
    "020_statuses":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9zdGF0dXMgP3Rlcm1pbmFsID9wYXJrZWQgP2ZvcndhcmQgV0hFUkUgewogID9zIGEgcGNwOlN0YXRlIDsgcmRmczpsYWJlbCA/c3RhdHVzIDsgcGNwOnRlcm1pbmFsID90ZXJtaW5hbCAuCiAgT1BUSU9OQUwgeyA/cyBwY3A6cGFya2VkID9wYXJrZWQgfQogIE9QVElPTkFMIHsgP3MgcGNwOmZvcndhcmQgP2ZvcndhcmQgfQp9Ck9SREVSIEJZID9zdGF0dXMK",
    "030_transitions":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9mcm9tID90byBXSEVSRSB7CiAgP3QgYSBwY3A6VHJhbnNpdGlvbiA7IHBjcDpmcm9tID9mIDsgcGNwOnRvID9nIC4KICA/ZiByZGZzOmxhYmVsID9mcm9tIC4gP2cgcmRmczpsYWJlbCA/dG8gLgp9Ck9SREVSIEJZID9mcm9tID90bwo=",
    "040_actions":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9vcmRlciA/YWN0aW9uID9wYXJhbSA/ZWZmZWN0IFdIRVJFIHsKICA/YSBhIHBjcDpBY3Rpb24gOyByZGZzOmxhYmVsID9hY3Rpb24gOyBwY3A6cGFyYW0gP3BhcmFtIDsgcGNwOm9yZGVyID9vcmRlciA7IHBjcDplZmZlY3QgP2VmZmVjdCAuCn0KT1JERVIgQlkgP29yZGVyCg==",
    "050_guards":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9hY3Rpb24gP2dvcmRlciA/Z2lkID9leHByIFdIRVJFIHsKICA/ZyBhIHBjcDpHdWFyZCA7IHBjcDpvZkFjdGlvbiA/YSA7IHBjcDpndWFyZElkID9naWQgOyBwY3A6Z3VhcmRPcmRlciA/Z29yZGVyIDsgcGNwOmV4cHIgP2V4cHIgLgogID9hIHJkZnM6bGFiZWwgP2FjdGlvbiAuCn0KT1JERVIgQlkgP2FjdGlvbiA/Z29yZGVyCg==",
    "060_properties":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClBSRUZJWCByZGZzOiA8aHR0cDovL3d3dy53My5vcmcvMjAwMC8wMS9yZGYtc2NoZW1hIz4KU0VMRUNUIERJU1RJTkNUID9vcmRlciA/bmFtZSA/a2luZCA/ZXhwciBXSEVSRSB7CiAgP3AgYSBwY3A6UHJvcGVydHkgOyByZGZzOmxhYmVsID9uYW1lIDsgcGNwOmtpbmQgP2tpbmQgOyBwY3A6b3JkZXIgP29yZGVyIDsgcGNwOmV4cHIgP2V4cHIgLgp9Ck9SREVSIEJZID9vcmRlcgo=",
    "070_mutants":
        "UFJFRklYIHBjcDogPGh0dHBzOi8vc2VhbmNoYXRtYW5ncHQuZ2l0aHViLmlvL3BhY2tzL2FzaC1wcGxhbi1wcm90b2NvbC1jb3VydCM+ClNFTEVDVCBESVNUSU5DVCA/bXV0YW50SWQgP2d1YXJkRHJvcCBXSEVSRSB7CiAgP20gYSBwY3A6TXV0YW50IDsgcGNwOm11dGFudElkID9tdXRhbnRJZCA7IHBjcDpndWFyZERyb3AgP2d1YXJkRHJvcCAuCn0KT1JERVIgQlkgP211dGFudElkCg==",
}
_pd_pack = os.path.join(here, "ash-pplan-protocol-court-pack")
_pd_verify = os.path.join(_pd_pack, "verify")
os.makedirs(_pd_verify, exist_ok=True)
for _stem, _b64 in sorted(_PD.items()):
    import base64 as _b
    _pos = _b.b64decode(_b64).decode()
    _g = os.path.join(_pd_pack, "gates", _stem + ".rq")
    if not os.path.isfile(_g):
        sys.exit(f"sync.sh: protocol gate missing to patch: {_stem}.rq")
    _old = open(_g).read()
    if "FILTER NOT EXISTS" in _old:
        _v = os.path.join(_pd_verify, _stem + ".violation.rq")
        if not os.path.isfile(_v):
            open(_v, "w").write(_old)
    if _old != _pos:
        open(_g, "w").write(_pos)
        patched.append(f"ash-pplan-protocol-court-pack/gates/{_stem}.rq")

# vendored whole-packs: gates/*.rq
for _pack in vendored_packs:
    _gd = os.path.join(here, _pack, "gates")
    if os.path.isdir(_gd):
        for _name in sorted(os.listdir(_gd)):
            if _name.endswith(".rq"):
                _hygiene_patch(os.path.join(_pack, "gates", _name))

# runtime-overlay gates: after the 2b/2e patches so patched copies get it too.
_ogd = os.path.join(rt_overlay, "gates")
for _name in sorted(os.listdir(_ogd)):
    if _name.endswith(".rq"):
        p = os.path.join(_ogd, _name)
        t = open(p).read()
        if (
            _hy_re.search(r"ORDER\s+BY", t, _hy_re.I)
            and not _hy_re.search(r"SELECT\s+DISTINCT", t, _hy_re.I)
            and (
                (s := _hy_re.search(r"SELECT\s+(.+?)\s*WHERE", t, _hy_re.S | _hy_re.I))
                is not None
            )
            and not _HY_KEY_RE.search(s.group(1))
        ):
            open(p, "w").write(_hy_re.sub(r"\bSELECT\b", "SELECT DISTINCT", t, count=1))
            patched.append(f"gates/{_name}")

# ---- 2g. verify/ re-home + witnesses/ shield (ECO-GATE-CONVENTION R0) -------
# state-transition-pack + evidence-standing-pack ship their offender gates in
# gates/ upstream, but ggen.toml [law] binds the verify/ re-homes per
# ECO-GATE-CONVENTION-DECISION (R0, 2026-10-04): a plain sync would rm -rf the
# pack and drop the re-homes + both-way witnesses (the 2026-10-04 07:43 wipe).
# After the copy, per pack:
#   1. re-home: gates/<offender>.rq -> verify/<stem>.unbound.rq (byte copy;
#      offender convention: 0 rows = PASS); literal-scan scripts move to
#      verify/ as-is;
#   2. rebuild witnesses/{pass,fail}/<stem>.ttl from the embedded tarball
#      (fixtures already on disk win, so hand-tuned fixtures survive);
#   3. retire the stale gates/ offender copies once their verify twin exists
#      (witness-shaped gates/030/040 of state-transition-pack stay).
# Upstream verify/ wins where the marketplace pack ships one. Idempotent.
_RH = {
    "state-transition-pack": {
        "rq": ("010_no_skipping_executed", "020_no_skipped_transitions"),
        "py": ("050_template_literal_scan.py",),
    },
    "evidence-standing-pack": {
        "rq": ("010_no_receipt_no_standing", "020_seal_once",
               "030_parent_hash_closure", "040_algorithm_supported_set",
               "060_outcome_requires_pending", "065_standing_only_on_outcome",
               "070_unpaired_pending"),
        "py": ("050_literal_scan.py",),
    },
}

# Embedded both-way witness fixtures (witnesses/{pass,fail}/<stem>.ttl),
# base64(tar czf) per pack; a file already on disk wins, so hand-tuned
# fixtures survive a sync.
_W_BLOB = {
    "state-transition-pack":
        "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",
    "evidence-standing-pack":
        "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",
}

for _pack, _m in _RH.items():
    _d = os.path.join(here, _pack)
    if os.path.isdir(os.path.join(market, "packs", _pack, "verify")):
        continue  # upstream verify/ wins; the bash loop already copied it
    _vd = os.path.join(_d, "verify")
    os.makedirs(_vd, exist_ok=True)
    for _stem in _m["rq"]:
        _g = os.path.join(_d, "gates", _stem + ".rq")
        if os.path.isfile(_g):
            shutil.copyfile(_g, os.path.join(_vd, _stem + ".unbound.rq"))
    for _py in _m["py"]:
        _g = os.path.join(_d, "gates", _py)
        if os.path.isfile(_g):
            shutil.copyfile(_g, os.path.join(_vd, _py))
    import base64 as _b64, io as _io, tarfile as _tar
    _buf = _io.BytesIO(_b64.b64decode(_W_BLOB[_pack]))
    with _tar.open(fileobj=_buf, mode="r:gz") as _tf:
        for _mem in _tf.getmembers():
            if not os.path.exists(os.path.join(_d, _mem.name)):
                _tf.extract(_mem, path=_d)
    for _stem in _m["rq"]:
        _g = os.path.join(_d, "gates", _stem + ".rq")
        if os.path.isfile(_g) and os.path.isfile(os.path.join(_vd, _stem + ".unbound.rq")):
            os.remove(_g)
    for _py in _m["py"]:
        _g = os.path.join(_d, "gates", _py)
        if os.path.isfile(_g) and os.path.isfile(os.path.join(_vd, _py)):
            os.remove(_g)

# ---- 3. lock + provenance ---------------------------------------------------
lock = {"schema": "ash_pplan.ggen.vendor-lock/v1", "source_repo": "ggen-marketplace",
        "source_git_sha": head, "packs": []}
ttl = ["# GENERATED by priv/ggen/vendor/sync.sh from PACKS.lock.json. Do not edit.",
       "@prefix tdbv: <https://chatman.ai/ash_pplan/vendor#> .",
       "@prefix prov: <http://www.w3.org/ns/prov#> .",
       "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .", ""]

# Whole-vendored packs: ontology + pack.toml + gates + templates (+ verify/
# when the pack ships it), each file sha256-locked. Tokyo-depeg is the first
# entry (W1 order preserved); ash-pplan-protocol-court-pack is second
# (ECO-PROTOCOL-COURT adoption), so the lock diff stays a clean append.
for pack_name in vendored_packs:
    pack_dir = os.path.join(here, pack_name)
    toml = open(os.path.join(market, "packs", pack_name, "pack.toml")).read()
    version = re.search(r'^version\s*=\s*"([^"]+)"', toml, re.M).group(1)
    dirty = git("status", "--porcelain", "--", f"packs/{pack_name}") != ""
    entries = [(f"{pack_name}/ontology.ttl", f"packs/{pack_name}/ontology.ttl", False),
               (f"{pack_name}/pack.toml", f"packs/{pack_name}/pack.toml", False)]
    if os.path.isfile(os.path.join(pack_dir, "gate-court.toml")):
        entries.append((f"{pack_name}/gate-court.toml",
                        f"packs/{pack_name}/gate-court.toml", False))
    for sub in ("gates", "templates", "queries", "tests", "verify",
                "fixtures", "qualification", "witnesses"):
        d = os.path.join(pack_dir, sub)
        if os.path.isdir(d):
            for root, dirs, files in os.walk(d):
                dirs.sort()
                for name in sorted(files):
                    rel = os.path.relpath(os.path.join(root, name), pack_dir)
                    entries.append((f"{pack_name}/{rel}", f"packs/{pack_name}/{rel}", False))
    files = []
    for rel, srcrel, _ in entries:
        src_file = os.path.join(market, "packs", pack_name, rel[len(pack_name) + 1:])
        src_sha = sha256(src_file) if os.path.exists(src_file) else None
        files.append({"path": rel, "source_path": srcrel,
                      "patched": src_sha is None or src_sha != sha256(os.path.join(here, rel)),
                      "sha256": sha256(os.path.join(here, rel))})
    lock["packs"].append({"name": pack_name, "version": version,
                          "source_tree_dirty": dirty, "files": files})
    onto = files[0]["sha256"]
    iri = "tdbv:pack_" + pack_name.replace("-", "_")
    ttl += [f"{iri} a prov:Entity ;",
            f'    tdbv:packName "{pack_name}" ;',
            f'    tdbv:packVersion "{version}" ;',
            f'    tdbv:packOntologySha256 "{onto}" ;',
            f'    tdbv:sourceGitSha "{head}" ;',
            f'    tdbv:sourceTreeDirty "{str(dirty).lower()}"^^xsd:boolean .', ""]

# runtime-integration pack: vendored surfaces live in the consumer overlay;
# ontology.ttl is consumer-authored and locked by SOURCE sha256 in provenance.
rt_version = re.search(r'^version\s*=\s*"([^"]+)"',
                       open(os.path.join(rt_src, "pack.toml")).read(), re.M).group(1)
rt_dirty = git("status", "--porcelain", "--", f"packs/{rt_pack}") != ""
# Shape-(b) provenance law (mirrors bin/gate's provenance_digest_verify):
# an overlayPath entry's packOntologySha256 is checked against the sha256 of
# the CONSUMER overlay ontology.ttl (<overlayPath>/ontology.ttl), not the
# marketplace pack's. The overlay ontology is consumer-authored (it carries
# the rt: individuals moved out of the pack), so the two diverged at
# commit 44e81f8 and the old rt_src sha became a permanent court failure.
# Record the overlay file's own sha256.
rt_onto_sha = sha256(os.path.join(rt_overlay, "ontology.ttl"))
rt_files = []
for sub in ("templates", "gates", "queries"):
    d = os.path.join(rt_overlay, sub)
    for name in sorted(os.listdir(d)):
        rel = f"{sub}/{name}"
        srcrel = f"packs/{rt_pack}/{rel}"
        if not os.path.exists(os.path.join(rt_src, rel)):
            # ERRRC-R4 fix (phantom source_paths): gate mirrors (the five
            # phase-2 driver queries copied into gates/ at step 2e, plus the
            # 140 saga driver) have no packs/<rt>/gates/<name> upstream —
            # record their real source, queries/<name>, instead.
            alt = f"packs/{rt_pack}/queries/{name}"
            if os.path.exists(os.path.join(market, alt)):
                srcrel = alt
        src_sha = sha256(os.path.join(market, srcrel)) if os.path.exists(os.path.join(market, srcrel)) else None
        rt_files.append({"path": f"../ash-pplan-runtime-overlay/{rel}",
                         "source_path": srcrel,
                         "patched": src_sha is None or src_sha != sha256(os.path.join(d, name)),
                         "sha256": sha256(os.path.join(d, name))})
lock["packs"].append({"name": rt_pack, "version": rt_version,
                      "source_tree_dirty": rt_dirty,
                      "consumer_authored": ["ontology.ttl (consumer overlay graph)"],
                      "patched": sorted(set(patched)),
                      "files": rt_files})
iri = "tdbv:pack_" + rt_pack.replace("-", "_")
ttl += [f"{iri} a prov:Entity ;",
        f'    tdbv:packName "{rt_pack}" ;',
        f'    tdbv:packVersion "{rt_version}" ;',
        f'    tdbv:packOntologySha256 "{rt_onto_sha}" ;',
        f'    tdbv:overlayPath "priv/ggen/ash-pplan-runtime-overlay" ;',
        f'    tdbv:sourceGitSha "{head}" ;',
        f'    tdbv:sourceTreeDirty "{str(rt_dirty).lower()}"^^xsd:boolean .', ""]

# --- specimen twins (sha-pinned, NOT vendored) ------------------------------
# The marketplace twins of the consumer-local dc:/sc: packs are recorded as
# sha-pinned specimens so twin drift is court-visible instead of silent: the
# lock carries both sides' ontology sha256 + the local pack dir + the
# marketplace HEAD, so any change on either side lands as a PACKS.lock.json
# diff. Local packs WIN: their generators are live (dc: ->
# bin/manufacture-durable-chaos -> test/durable/chaos; sc: ->
# bin/manufacture-store-conformance -> test/support/durable/
# store_conformance.ex), the marketplace twins are unconsumed generalized
# copies (acp:/scb:) kept only as upstream-adoption candidates.
specimens = [
    ("ash-pplan-chaos-pack", "priv/ggen/ash-pplan-durable-chaos-pack",
     "local ash-pplan-durable-chaos-pack wins (live dc: generator); acp: "
     "twin is an unconsumed specimen; known divergence witness: dc:/acp: "
     "replay_identity dc:title differs (local: 'replaying a completed run "
     "re-executes nothing...', marketplace: 'replaying a completed unit of "
     "work re-executes nothing...')"),
    ("ash-pplan-store-conformance-pack",
     "priv/ggen/ash-pplan-store-conformance-pack",
     "local sc: 14-law pack wins (live generator); scb: twin is an "
     "unconsumed specimen"),
]
lock["specimens"] = []
repo_root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
for sp_name, sp_local, sp_note in specimens:
    sp_mkt = os.path.join(market, "packs", sp_name)
    if not os.path.isfile(os.path.join(sp_mkt, "ontology.ttl")):
        sys.exit(f"sync.sh: specimen pack missing ontology.ttl: {sp_mkt}")
    if not os.path.isfile(os.path.join(market, "packs", sp_name, "pack.toml")):
        sys.exit(f"sync.sh: specimen pack missing pack.toml: {sp_mkt}")
    sp_loc_onto = os.path.join(repo_root, sp_local, "ontology.ttl")
    if not os.path.isfile(sp_loc_onto):
        sys.exit(f"sync.sh: specimen local twin missing ontology.ttl: {sp_loc_onto}")
    sp_m = re.search(r'^version\s*=\s*"([^"]+)"',
                     open(os.path.join(sp_mkt, "pack.toml")).read(), re.M)
    sp_ver = sp_m.group(1) if sp_m else "unversioned"
    sp_mkt_sha = sha256(os.path.join(sp_mkt, "ontology.ttl"))
    sp_loc_sha = sha256(sp_loc_onto)
    lock["specimens"].append({
        "name": sp_name, "version": sp_ver, "source_git_sha": head,
        "role": "specimen-not-vendored", "local_pack": sp_local,
        "marketplace_ontology_sha256": sp_mkt_sha,
        "local_ontology_sha256": sp_loc_sha,
        "ontologies_identical": sp_mkt_sha == sp_loc_sha,
        "note": sp_note})
    iri = "tdbv:specimen_" + sp_name.replace("-", "_")
    ttl += [f"{iri} a prov:Entity ;",
            f'    tdbv:packName "{sp_name}" ;',
            f'    tdbv:packVersion "{sp_ver}" ;',
            f'    tdbv:marketplaceOntologySha256 "{sp_mkt_sha}" ;',
            f'    tdbv:localOntologySha256 "{sp_loc_sha}" ;',
            f'    tdbv:localPack "{sp_local}" ;',
            f'    tdbv:sourceGitSha "{head}" ;',
            '    tdbv:specimenRole "not-vendored-consumer-local-pack-wins" .', ""]

with open(os.path.join(here, "provenance.ttl"), "w") as f:
    f.write("\n".join(ttl) + "\n")
lock["generated"] = [{"path": "provenance.ttl", "sha256": sha256(os.path.join(here, "provenance.ttl"))}]
with open(os.path.join(here, "PACKS.lock.json"), "w") as f:
    json.dump(lock, f, indent=2)
    f.write("\n")
print("sync.sh: vendored %s (sha256-locked) + %s overlay (%d files, %d patched)" % (
    " ".join(vendored_packs), rt_pack, len(rt_files), len(set(patched))))
PY
echo "sync.sh: vendored ${packs[*]} + $rt_pack overlay from $market (sha256-locked at $head_sha)"
