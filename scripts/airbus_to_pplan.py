#!/usr/bin/env python3
"""Airbus test translation layer: unified-planning Problem -> p-plan Turtle.

Mapping: up:Problem -> p-plan:Plan; actions -> p-plan:Step; fluents ->
p-plan:Variable; preconditions -> p-plan:hasInputVar; effects ->
p-plan:hasOutputVar; durative -> ap:min/maxDuration; goals -> absorbing.
"""
import sys
from pathlib import Path

import rdflib
from rdflib import Graph, Literal
from rdflib.namespace import RDF, RDFS, XSD

from unified_planning.io import PDDLReader
from unified_planning.model import DurativeAction

PPLAN = rdflib.Namespace("http://ontology.eil.utoronto.ca/p-plan/")
AP = rdflib.Namespace("https://ash_pplan.example/airbus-parity#")
UPP = rdflib.Namespace("https://ash_pplan.example/up#")


def sanitize(name):
    out = []
    for ch in name:
        if ch.isalnum() and ch.isascii():
            out.append(ch)
        else:
            out.append("_")
    s = "".join(out)
    if not s or not (s[0].isalpha() and s[0].isascii()):
        s = "n_" + s
    return s


def atom_fluent_names(expr):
    """Base fluent names referenced by a condition expression."""
    names = set()
    try:
        atoms = set()
        expr._collect_atoms(atoms)
        for a in atoms:
            f = getattr(a, "fluent", None)
            if f is not None:
                names.add(f.name)
    except Exception:
        pass
    return names


def effect_fluent_name(effect):
    f = getattr(effect, "fluent", None)
    for _ in range(16):
        if f is None:
            return "UNKNOWN_FLUENT"
        inner = getattr(f, "fluent", None)
        if inner is None:
            break
        f = inner
    return getattr(f, "name", str(f))


def duration_bounds(dur):
    def cv(v):
        if v is None:
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            pass
        try:
            return float(v)
        except (TypeError, ValueError):
            pass
        return str(v)

    lower = getattr(dur, "lower", None)
    upper = getattr(dur, "upper", None)
    ld = getattr(lower, "delay", None)
    ud = getattr(upper, "delay", None)
    if ld is not None:
        lower = ld
    if ud is not None:
        upper = ud
    return cv(lower), cv(upper)


def transpile(up_problem, fallback_name):
    g = Graph()
    g.bind("p-plan", PPLAN)
    g.bind("ap", AP)
    g.bind("up", UPP)

    pname = up_problem.name or fallback_name
    prob = UPP[sanitize(pname)]
    g.add((prob, RDF.type, PPLAN.Plan))
    g.add((prob, RDF.type, AP.AirbusParityCase))
    g.add((prob, RDFS.label, Literal(pname)))

    for fl in up_problem.fluents:
        firi = UPP["fluent_" + sanitize(fl.name)]
        g.add((firi, RDF.type, PPLAN.Variable))
        g.add((firi, RDFS.label, Literal(fl.name)))
        g.add((prob, AP.hasVariable, firi))

    for act in up_problem.actions:
        airi = UPP["step_" + sanitize(act.name)]
        g.add((airi, RDF.type, PPLAN.Step))
        g.add((airi, RDFS.label, Literal(act.name)))
        g.add((prob, rdflib.namespace.Namespace(
            "http://ontology.eil.utoronto.ca/p-plan#").has_step, airi))

        precs = set()
        effs = set()
        dur_obj = None
        if isinstance(act, DurativeAction):
            dur_obj = act.duration
            for cond in act.conditions.values():
                precs |= atom_fluent_names(cond)
            for efflist in act.effects.values():
                for eff in efflist:
                    effs.add(effect_fluent_name(eff))
        else:
            for cond in act.preconditions:
                precs |= atom_fluent_names(cond)
            for eff in act.effects:
                effs.add(effect_fluent_name(eff))

        for p in sorted(precs):
            g.add((airi, PPLAN.hasInputVar, UPP["fluent_" + sanitize(p)]))
        for e in sorted(effs):
            g.add((airi, PPLAN.hasOutputVar, UPP["fluent_" + sanitize(e)]))

        if dur_obj is not None:
            lo, hi = duration_bounds(dur_obj)
            if lo is not None:
                g.add((airi, AP.minDuration, Literal(lo, datatype=XSD.integer)))
            if hi is not None:
                g.add((airi, AP.maxDuration, Literal(hi, datatype=XSD.integer)))

    return g


def main():
    base = Path(__file__).resolve().parent.parent
    corpus_root = base / "priv/courts/airbus_parity/corpus"
    out_root = corpus_root / "transpiled"
    out_root.mkdir(parents=True, exist_ok=True)

    results = []
    case_dirs = []
    for p in sorted(corpus_root.rglob("*.pddl")):
        cd = p.parent
        if cd == corpus_root:
            continue  # root-level standalone files (po/fond singles): not pair cases
        if cd not in case_dirs:
            case_dirs.append(cd)
    for case_dir in case_dirs:
        doms = sorted(case_dir.glob("domain*.pddl")) or sorted(case_dir.glob("d.pddl"))
        probs = sorted(case_dir.glob("problem*.pddl")) or sorted(case_dir.glob("p.pddl"))
        if not doms or not probs:
            print("SKIP %s: missing domain/problem files" % case_dir.name, file=sys.stderr)
            results.append((case_dir.name, "FAIL", "missing files"))
            continue
        reader = PDDLReader()
        try:
            up_problem = reader.parse_problem(str(doms[0]), str(probs[0]))
        except Exception as e:
            print("SKIP %s: UP parse failed: %s" % (case_dir.name, e), file=sys.stderr)
            results.append((case_dir.name, "FAIL", "up-parse-failed"))
            continue

        try:
            g = transpile(up_problem, case_dir.name)
            data = g.serialize(format="turtle")
            g2 = Graph()
            g2.parse(data=data, format="turtle")
        except Exception as e:
            print("FAIL %s: %s: %s" % (case_dir.name, type(e).__name__, e), file=sys.stderr)
            results.append((case_dir.name, "FAIL", type(e).__name__))
            continue

        n_steps = sum(1 for t in g2.triples((None, RDF.type, PPLAN.Step)))
        n_vars = sum(1 for t in g2.triples((None, RDF.type, PPLAN.Variable)))
        (out_root / (case_dir.name + ".ttl")).write_text(data)
        print("PASS %s: %d triples, %d steps, %d variables" % (case_dir.name, len(g2), n_steps, n_vars))
        results.append((case_dir.name, "PASS", "%d triples / %d steps / %d vars" % (len(g2), n_steps, n_vars)))

    npass = sum(1 for r in results if r[1] == "PASS")
    print("")
    print("%d/%d corpus cases transpiled+parsed" % (npass, len(results)))
    if npass != len(results):
        sys.exit(1)


if __name__ == "__main__":
    main()
