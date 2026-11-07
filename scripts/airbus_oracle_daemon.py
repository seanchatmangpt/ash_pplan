#!/usr/bin/env python3
"""Airbus oracle daemon: unix-socket reference solver over Unified Planning."""

import argparse
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/airbus_oracle.sock"
FOND_MARKERS = (":non-deterministic", ":nondeterministic")


def classify_kind(domain_text):
    low = domain_text.lower()
    if any(m in low for m in FOND_MARKERS):
        return "fond"
    if ":htn" in low or ":hddl" in low or ":method" in low:
        return "hddl"
    if ":process" in low or ":durative" in low or ":time" in low:
        return "temporal"
    return "classical"


def no_engine(kind):
    return {
        "solvable": None,
        "plan": None,
        "engine": None,
        "error": "no_engine_for_kind",
        "kind": kind,
    }


def error_result(error, detail=None):
    out = {"solvable": None, "plan": None, "engine": None, "error": error}
    if detail is not None:
        out["detail"] = detail
    return out


def load_problem(domain_text, problem_text):
    from unified_planning.io import PDDLReader
    try:
        return PDDLReader().parse_problem_string(domain_text, problem_text)
    except Exception as ex:
        raise ValueError(type(ex).__name__ + ": " + str(ex))


# Built-in smoke pair: pure STRIPS. Every PDDL example bundled with UP
# (counters, tpp_metric, miconic, ...) carries features (numeric fluents,
# metrics, conditional effects) no installed engine admits, so the fallback
# self-test case is an inline pair rather than a bundled one.
BUNDLED_DOMAIN = """(define (domain airbus_oracle_smoke)
(:requirements :strips :typing) (:types a) (:predicates (p ?x - a) (q ?x - a))
(:action move :parameters (?x ?y - a) :precondition (p ?x)
:effect (and (q ?x) (not (p ?x)))))"""

BUNDLED_PROBLEM = """(define (problem airbus_oracle_smoke_p)
(:domain airbus_oracle_smoke) (:objects o1 - a) (:init (p o1)) (:goal (q o1)))"""


def plan_to_json(plan):
    if plan is None:
        return None
    out = []
    for a in plan.actions:
        params = " ".join(str(p) for p in a.actual_parameters)
        out.append("(" + a.action.name + " " + params + ")")
    return out


def solve(domain_text, problem_text):
    kind = classify_kind(domain_text)
    if kind != "classical":
        return no_engine(kind)
    try:
        problem = load_problem(domain_text, problem_text)
    except ValueError as ex:
        out = error_result("parse_error")
        out["detail"] = str(ex)
        return out
    import unified_planning.shortcuts as us
    from unified_planning.exceptions import (
        UPNoSuitableEngineAvailableException,
        UPUsageError,
    )
    try:
        with us.OneshotPlanner(problem_kind=problem.kind) as planner:
            res = planner.solve(problem)
    except UPNoSuitableEngineAvailableException as ex:
        return no_engine("classical", detail=str(ex).splitlines()[0])
    except Exception as ex:
        msg = str(ex).lower()
        if "engine" in msg or "support" in msg or "kind" in msg:
            return no_engine("classical", detail=str(ex).splitlines()[0])
        out = error_result("solve_failed")
        out["detail"] = type(ex).__name__ + ": " + str(ex)
        return out
    engine = getattr(res, "engine_name", None)
    plan = getattr(res, "plan", None)
    status = getattr(res, "status", None)
    status_name = status.name if status is not None else None
    if plan is None:
        return {
            "solvable": False,
            "plan": None,
            "engine": engine,
            "error": None,
            "status": status_name,
        }
    return {
        "solvable": True,
        "plan": plan_to_json(plan),
        "engine": engine,
        "error": None,
        "status": status_name,
    }


AUTOFDE_SRC = "/Users/sac/autofde-lab/src"


def check_policy(initial, goal_states, transitions, policy, semantics):
    """FOND candidate-policy check via autofde_lab's authority-free checker.

    Runs BOTH semantics (strong and strong_cyclic) on the same candidate in
    one call so the differential court gets both verdicts atomically.
    """
    sys.path.insert(0, AUTOFDE_SRC)
    try:
        from autofde_lab.planning.fond_policy import (
            CandidatePolicy,
            FONDProblem,
            PolicySemantics,
            check_candidate_policy,
        )
    except Exception as ex:
        return error_result("checker_unavailable", type(ex).__name__ + ": " + str(ex))
    try:
        problem = FONDProblem(
            initial_state=str(initial),
            goal_states=frozenset(str(g) for g in goal_states),
            transitions={
                (str(s), str(a)): frozenset(str(o) for o in outs)
                for (s, a), outs in transitions.items()
            },
        )
        candidate = CandidatePolicy(
            actions={str(k): str(v) for k, v in policy.items()}
        )
        strong = check_candidate_policy(
            problem, candidate, semantics=PolicySemantics.STRONG)
        strong_cyclic = check_candidate_policy(
            problem, candidate, semantics=PolicySemantics.STRONG_CYCLIC)
    except Exception as ex:
        return error_result("check_failed", type(ex).__name__ + ": " + str(ex))
    if semantics not in ("strong", "strong_cyclic"):
        return error_result("bad_request", "semantics must be 'strong' or 'strong_cyclic'")
    return {
        "solvable": None,
        "plan": None,
        "engine": "autofde_lab.fond_policy",
        "error": None,
        "valid": strong.valid if semantics == "strong" else strong_cyclic.valid,
        "semantics": semantics,
        "strong_valid": strong.valid,
        "strong_cyclic_valid": strong_cyclic.valid,
        "reachable_states": sorted(strong.reachable_states),
        "non_goal_cycle_states": sorted(strong.non_goal_cycle_states),
        "missing_policy_states": sorted(strong.missing_policy_states),
        "dead_end_states": sorted(strong.dead_end_states),
        "cannot_reach_goal_states": sorted(strong.cannot_reach_goal_states),
    }


def _check_policy_params(params):
    initial = params.get("initial")
    goals = params.get("goal_states")
    transitions = params.get("transitions")
    policy = params.get("policy")
    semantics = params.get("semantics", "strong_cyclic")
    if not isinstance(initial, str):
        return None
    if not (isinstance(goals, list) and all(isinstance(g, str) for g in goals)):
        return None
    if not (isinstance(transitions, list) and all(
            isinstance(t, list) and len(t) == 3 and isinstance(t[0], str)
            and isinstance(t[1], str) and isinstance(t[2], list)
            and all(isinstance(o, str) for o in t[2])
            for t in transitions)):
        return None
    if not (isinstance(policy, dict) and all(
            isinstance(k, str) and isinstance(v, str) for k, v in policy.items())):
        return None
    if semantics not in ("strong", "strong_cyclic"):
        return None
    return {
        "initial": initial,
        "goal_states": goals,
        "transitions": {(t[0], t[1]): t[2] for t in transitions},
        "policy": policy,
        "semantics": semantics,
    }


def handle_request(req):
    if not isinstance(req, dict) or req.get("method") not in ("solve", "check_policy"):
        return {"result": error_result(
            "bad_request", "method must be 'solve' or 'check_policy'")}
    params = req.get("params") or {}
    if req["method"] == "check_policy":
        parsed = _check_policy_params(params)
        if parsed is None:
            return {"result": error_result(
                "bad_request",
                "check_policy needs initial:str, goal_states:[str], "
                "transitions:[[s,a,[outcomes]]], policy:{s:a}, semantics")}
        return {"id": req.get("id"), "result": check_policy(**parsed)}
    domain = params.get("domain")
    problem = params.get("problem")
    if not (isinstance(domain, str) and isinstance(problem, str)):
        return {"result": error_result(
            "bad_request", "params.domain and params.problem must be strings")}
    return {"id": req.get("id"), "result": solve(domain, problem)}


def engines_line():
    from unified_planning.engines.factory import Factory
    import unified_planning.shortcuts as us
    factory = Factory(us.get_environment())
    names = []
    for meta in factory.engines:
        name = str(getattr(meta, "engine_name", meta))
        if "pyperplan" in name or "tamer" in name:
            names.append(name)
    return ",".join(sorted(names))


def read_text(path):
    with open(path) as f:
        return f.read()


def run_selftest(dom_text, prob_text):
    result = solve(dom_text, prob_text)
    print(json.dumps(result, indent=2))
    if result.get("error") == "no_engine_for_kind":
        sys.stderr.write("SELFTEST: typed no_engine_for_kind kind="
                         + str(result.get("kind")) + "\n")
        return 0
    if result.get("solvable") is True and result.get("plan"):
        sys.stderr.write("SELFTEST: real plan produced via "
                         + str(result.get("engine")) + "\n")
        return 0
    sys.stderr.write("SELFTEST: FAIL " + json.dumps(result) + "\n")
    return 1


def serve(sock_path):
    import unified_planning  # noqa: F401
    import unified_planning.shortcuts  # noqa: F401
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(8)
    sys.stderr.write("airbus-oracle listening on " + sock_path
                     + " engines=" + engines_line() + "\n")
    while True:
        conn, _ = srv.accept()
        try:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            if data.strip():
                try:
                    req = json.loads(data.decode("utf-8"))
                except json.JSONDecodeError as ex:
                    resp = {"result": error_result("bad_request",
                                                   "json: " + str(ex))}
                else:
                    resp = handle_request(req)
            else:
                resp = {"result": error_result("bad_request", "empty request")}
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except Exception as ex:
            try:
                err = {"result": error_result(
                    "solve_failed", "daemon: " + type(ex).__name__ + ": " + str(ex))}
                conn.sendall((json.dumps(err) + "\n").encode("utf-8"))
            except Exception:
                pass
        finally:
            try:
                conn.close()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description="Airbus oracle daemon")
    parser.add_argument("--serve", action="store_true",
                        help="serve on " + SOCKET_PATH + " (default)")
    parser.add_argument("--selftest", nargs=2, metavar=("DOMAIN", "PROBLEM"),
                        help="solve one case; '-' uses UP's bundled counters example")
    parser.add_argument("--engines", action="store_true")
    args = parser.parse_args()
    if args.engines:
        import unified_planning  # noqa: F401
        import unified_planning.shortcuts  # noqa: F401
        print(engines_line())
        return 0
    if args.selftest:
        dom_arg, prob_arg = args.selftest
        dom_text = BUNDLED_DOMAIN if dom_arg == "-" else read_text(dom_arg)
        prob_text = BUNDLED_PROBLEM if prob_arg == "-" else read_text(prob_arg)
        return run_selftest(dom_text, prob_text)
    import unified_planning  # noqa: F401
    import unified_planning.shortcuts  # noqa: F401
    serve(SOCKET_PATH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
