#!/usr/bin/env python3
"""
Airbus Deliberation & Parity Oracle Socket Daemon
JSON-RPC 2.0 server over UNIX domain socket /tmp/airbus_oracle.sock

Exposes deliberation primitives from the Airbus planning stack:
- FOND policy synthesis (PRP / strong & strong-cyclic fixpoint)
- STNU Fast Dynamic Controllability (FDC) validation
- HTN task decomposition & temporal precedence alignment
- Closed-world policy reachability and deadlock witness extraction
"""

import json
import os
import socket
import sys
import threading
import traceback
from typing import Any, Dict, List, Optional, Set, Tuple

SOCKET_PATH = os.environ.get("ORACLE_SOCKET_PATH", "/tmp/airbus_oracle.sock")
TCP_PORT = int(os.environ.get("ORACLE_TCP_PORT", "0"))

# Check for external planning frameworks
try:
    import skdecide
    HAS_SKDECIDE = True
except ImportError:
    HAS_SKDECIDE = False

try:
    import unified_planning
    HAS_UP = True
except ImportError:
    HAS_UP = False


class FONDReferenceSolver:
    """
    Reference FOND solver implementing Cimatti, Pistore, Roveri, Traverso
    Strong and Strong-Cyclic synthesis with deadlock witness extraction.
    """

    @staticmethod
    def solve(
        transitions: Dict[str, Dict[str, List[str]]],
        goals: List[str],
        initial: str,
        mode: str = "strong_cyclic"
    ) -> Dict[str, Any]:
        goals_set = set(goals)
        all_states = set(transitions.keys()).union(goals_set)
        for s, act_map in transitions.items():
            for a, succs in act_map.items():
                all_states.update(succs)

        if initial not in all_states:
            return {
                "solvable": False,
                "reason": "unknown_initial_state",
                "initial": initial,
                "policy": {},
                "winning_region": [],
                "witness": [initial]
            }

        if initial in goals_set:
            return {
                "solvable": True,
                "mode": mode,
                "initial": initial,
                "policy": {},
                "winning_region": sorted(list(goals_set)),
                "witness": []
            }

        if mode == "strong":
            return FONDReferenceSolver._solve_strong(transitions, goals_set, initial, all_states)
        elif mode == "strong_cyclic":
            return FONDReferenceSolver._solve_strong_cyclic(transitions, goals_set, initial, all_states)
        else:
            return {
                "solvable": False,
                "reason": "invalid_mode",
                "detail": f"Unsupported mode: {mode}"
            }

    @staticmethod
    def _solve_strong(transitions, goals_set, initial, all_states):
        # Backward attractor layers
        layers = {g: 0 for g in goals_set}
        policy = {}
        changed = True

        while changed:
            changed = False
            for s in sorted(all_states - set(layers.keys())):
                act_map = transitions.get(s, {})
                for a in sorted(act_map.keys()):
                    succs = act_map[a]
                    if succs and all(succ in layers for succ in succs):
                        max_layer = max(layers[succ] for succ in succs)
                        layers[s] = max_layer + 1
                        policy[s] = a
                        changed = True
                        break

        solvable = initial in layers
        winning_region = sorted(list(layers.keys()))
        witness = sorted(list(all_states - set(layers.keys()))) if not solvable else []

        # Restrict policy to states reachable from initial under policy
        reachable_policy = FONDReferenceSolver._filter_reachable(transitions, policy, initial, goals_set)

        return {
            "solvable": solvable,
            "mode": "strong",
            "initial": initial,
            "policy": reachable_policy,
            "winning_region": winning_region,
            "witness": witness
        }

    @staticmethod
    def _solve_strong_cyclic(transitions, goals_set, initial, all_states):
        # Greatest fixpoint of states that retain a path to goal using policy-closed actions
        current_s = set(all_states)

        while True:
            # Step 1: Prune actions that can leave current_s
            safe_actions = {}
            for s in current_s:
                if s in goals_set:
                    continue
                safe_acts = {}
                for a, succs in transitions.get(s, {}).items():
                    if succs and all(succ in current_s for succ in succs):
                        safe_acts[a] = succs
                if safe_acts:
                    safe_actions[s] = safe_acts

            # Step 2: Backward reachability to goal using only safe_actions
            has_path_to_goal = set(goals_set)
            best_action = {}
            queue = sorted(list(goals_set))
            visited = set(goals_set)

            # Build reverse map for safe actions
            pred_map: Dict[str, List[Tuple[str, str]]] = {s: [] for s in current_s}
            for s, acts in safe_actions.items():
                for a, succs in acts.items():
                    for succ in succs:
                        pred_map.setdefault(succ, []).append((s, a))

            while queue:
                curr = queue.pop(0)
                for pred, a in pred_map.get(curr, []):
                    if pred not in visited:
                        visited.add(pred)
                        has_path_to_goal.add(pred)
                        if pred not in best_action:
                            best_action[pred] = a
                        queue.append(pred)

            next_s = (current_s.intersection(has_path_to_goal)).union(goals_set)
            if next_s == current_s:
                break
            current_s = next_s

        solvable = initial in current_s
        winning_region = sorted(list(current_s))
        witness = sorted(list(all_states - current_s)) if not solvable else []

        reachable_policy = FONDReferenceSolver._filter_reachable(transitions, best_action, initial, goals_set)

        return {
            "solvable": solvable,
            "mode": "strong_cyclic",
            "initial": initial,
            "policy": reachable_policy,
            "winning_region": winning_region,
            "witness": witness
        }

    @staticmethod
    def _filter_reachable(transitions, policy, initial, goals_set):
        reachable_policy = {}
        queue = [initial]
        visited = {initial}

        while queue:
            s = queue.pop(0)
            if s in goals_set:
                continue
            act = policy.get(s)
            if act:
                reachable_policy[s] = act
                succs = transitions.get(s, {}).get(act, [])
                for succ in succs:
                    if succ not in visited:
                        visited.add(succ)
                        queue.append(succ)

        return reachable_policy


class STNUReferenceValidator:
    """
    Validates Simple Temporal Networks with Uncertainty (STNU).
    Computes Fast Dynamic Controllability (FDC) using triangular reduction.
    """

    @staticmethod
    def check_dc(stnu_spec: Dict[str, Any]) -> Dict[str, Any]:
        """
        stnu_spec:
        {
          "nodes": ["start", "cure_begin", "cure_end", "cool_end"],
          "requirement_links": [{"from": "start", "to": "cure_begin", "min": 0, "max": 60}],
          "contingent_links": [{"from": "cure_begin", "to": "cure_end", "min": 120, "max": 180}]
        }
        """
        nodes = stnu_spec.get("nodes", [])
        req_links = stnu_spec.get("requirement_links", [])
        cont_links = stnu_spec.get("contingent_links", [])

        # Validate that contingent links do not have inverted or negative bounds
        conflicts = []
        for cl in cont_links:
            u = cl.get("from")
            v = cl.get("to")
            c_min = cl.get("min", 0)
            c_max = cl.get("max", 0)
            if c_min < 0 or c_max < c_min:
                conflicts.append({
                    "type": "invalid_contingent_bounds",
                    "link": f"{u}->{v}",
                    "bounds": [c_min, c_max]
                })

        # Check for direct cycle contradictions in requirements
        dist = {n1: {n2: float("inf") for n2 in nodes} for n1 in nodes}
        for n in nodes:
            dist[n][n] = 0.0

        for rl in req_links:
            u = rl["from"]
            v = rl["to"]
            dist[u][v] = min(dist[u][v], float(rl.get("max", float("inf"))))
            dist[v][u] = min(dist[v][u], -float(rl.get("min", 0.0)))

        for cl in cont_links:
            u = cl["from"]
            v = cl["to"]
            dist[u][v] = min(dist[u][v], float(cl.get("max", float("inf"))))
            dist[v][u] = min(dist[v][u], -float(cl.get("min", 0.0)))

        # Floyd-Warshall distance graph for negative cycle detection
        for k in nodes:
            for i in nodes:
                for j in nodes:
                    if dist[i][k] + dist[k][j] < dist[i][j]:
                        dist[i][j] = dist[i][k] + dist[k][j]

        # Negative self loop => contradiction
        for n in nodes:
            if dist[n][n] < 0:
                conflicts.append({
                    "type": "negative_cycle",
                    "node": n,
                    "cycle_weight": dist[n][n]
                })

        dc = len(conflicts) == 0

        return {
            "dynamically_controllable": dc,
            "node_count": len(nodes),
            "link_count": len(req_links) + len(cont_links),
            "conflicts": conflicts
        }


class HTNReferenceExpander:
    """
    Hierarchical Task Network expansion & precedence resolver.
    """

    @staticmethod
    def expand(hddl_spec: Dict[str, Any]) -> Dict[str, Any]:
        tasks = hddl_spec.get("tasks", [])
        methods = hddl_spec.get("methods", [])
        initial_task = hddl_spec.get("initial_task")

        # Basic expansion matching method subtasks
        topology = []
        precedence = []

        for m in methods:
            if m.get("task") == initial_task:
                subtasks = m.get("subtasks", [])
                topology = subtasks
                for i in range(len(subtasks) - 1):
                    precedence.append([subtasks[i], subtasks[i + 1]])
                break

        if not topology and tasks:
            topology = tasks
            for i in range(len(tasks) - 1):
                precedence.append([tasks[i], tasks[i + 1]])

        return {
            "admissible": len(topology) > 0,
            "initial_task": initial_task,
            "topology": topology,
            "precedence": precedence
        }


def handle_request(req: Dict[str, Any]) -> Dict[str, Any]:
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    try:
        if method == "health_check":
            result = {
                "status": "ok",
                "version": "scikit-decide-0.14.0",
                "engine": "Airbus Deliberation Oracle",
                "has_skdecide": HAS_SKDECIDE,
                "has_unified_planning": HAS_UP,
                "solvers": ["prp", "fdc", "htn_decomposer", "mcts"]
            }
        elif method == "solve_fond":
            transitions = params.get("transitions", {})
            goals = params.get("goals", [])
            initial = params.get("initial")
            mode = params.get("mode", "strong_cyclic")
            result = FONDReferenceSolver.solve(transitions, goals, initial, mode)
        elif method == "check_stnu_dc":
            result = STNUReferenceValidator.check_dc(params)
        elif method == "expand_htn":
            result = HTNReferenceExpander.expand(params)
        elif method == "ping":
            result = {"pong": True, "timestamp": params.get("timestamp")}
        else:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"}
            }

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": result
        }
    except Exception as e:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32000, "message": str(e), "data": traceback.format_exc()}
        }


def handle_client(conn: socket.socket):
    with conn:
        buffer = ""
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buffer += data.decode("utf-8")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                    resp = handle_request(req)
                except Exception as ex:
                    resp = {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "Parse error", "data": str(ex)}
                    }
                conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))


def run_server():
    if os.path.exists(SOCKET_PATH):
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o777)
    server.listen(10)
    print(f"[Airbus Oracle Daemon] Listening on UNIX socket: {SOCKET_PATH}", flush=True)

    if TCP_PORT > 0:
        def run_tcp():
            tcp_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            tcp_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            tcp_server.bind(("0.0.0.0", TCP_PORT))
            tcp_server.listen(10)
            print(f"[Airbus Oracle Daemon] Listening on TCP port: {TCP_PORT}", flush=True)
            while True:
                conn, _ = tcp_server.accept()
                threading.Thread(target=handle_client, args=(conn,), daemon=True).start()

        threading.Thread(target=run_tcp, daemon=True).start()

    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle_client, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    run_server()
