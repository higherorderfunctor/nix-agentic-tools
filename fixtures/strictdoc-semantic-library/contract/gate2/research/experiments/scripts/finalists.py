"""Capability probes, not a semantic engine or a Scribe integration.

Run from any directory using the isolated venv. A NetworkX path oracle and
explicit expected rows control three distinct evaluator implementations.
"""

import copy
import importlib.metadata
import json
from pathlib import Path
import statistics
import subprocess
import time

from cozo_embedded import CozoDbPy
import networkx as nx
import rustworkx as rx

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
SELECTOR = {"model": "neutral", "owner_type": "record", "kind": "Parent", "role": "H"}


def relation(owner, target, *, kind="Parent", role="H", owner_type="record", model="neutral"):
    return {"model": model, "owner": owner, "owner_type": owner_type,
            "kind": kind, "role": role, "target": target}


def base():
    nodes = {n: {"closed": n == "F2"} for n in
             ["F0", "F1", "F1a", "F2", "F2a", "F2b", "G0", "G1", "I0", "Z0"]}
    pairs = [("F1", "F0"), ("F1a", "F1"), ("F2", "F0"),
             ("F2a", "F2"), ("F2b", "F2"), ("G1", "G0")]
    queries = [
        ("closed_endpoint", "F1a", "F2", "visible", True),
        ("blocked_interior", "F1a", "F2a", "visible", False),
        ("internal_peer", "F2a", "F2b", "visible", True),
        ("internal_exit", "F2a", "F1a", "visible", True),
        ("closed_start", "F2", "F2a", "downward", True),
        ("cross_root", "F1a", "G1", "visible", False),
        ("bridge_endpoint", "F0", "F2", "downward", True),
        ("bridge_blocked", "F0", "F2a", "downward", False),
        ("bridge_sibling", "F1", "F2", "downward", False),
        ("unselected_shortcut", "F0", "G1", "downward", False),
    ]
    return {"nodes": nodes, "relations": [relation(c, p) for c, p in pairs]
            + [relation("Z0", "F0", role="R", owner_type="other"),
               relation("Z0", "G1", kind="Child", role="Q", owner_type="other")],
            "hierarchy": SELECTOR,
            "queries": [{"id": i, "origin": o, "target": t, "mode": m, "expected": e}
                        for i, o, t, m, e in queries],
            "snapshot": {"id": "empty-1", "records": {}}, "projection": {}}


def selected_edges(data):
    edges = []
    for r in data["relations"]:
        if not all(r[k] == v for k, v in data["hierarchy"].items()):
            continue
        assert r["kind"] in {"Parent", "Child"}
        edges.append((r["target"], r["owner"]) if r["kind"] == "Parent"
                     else (r["owner"], r["target"]))
    return edges


def child_base():
    """Literal Child ownership and truth rows; not derived by reversing a helper."""
    data = base()
    data["hierarchy"] = {**SELECTOR, "kind": "Child"}
    data["relations"] = [relation(owner, target, kind="Child") for owner, target in
                         [("F0", "F1"), ("F1", "F1a"), ("F0", "F2"),
                          ("F2", "F2a"), ("F2", "F2b"), ("G0", "G1")]]
    # Same context but opposite native kind must remain outside this hierarchy.
    data["relations"].append(relation("G1", "F0", kind="Parent"))
    rows = [
        ("open_downward", "F0", "F1a", "downward", True),
        ("reverse_downward", "F1a", "F0", "downward", False),
        ("closed_endpoint", "F0", "F2", "downward", True),
        ("blocked_interior", "F0", "F2a", "downward", False),
        ("closed_start", "F2", "F2a", "downward", True),
        ("internal_peer", "F2a", "F2b", "visible", True),
        ("internal_exit", "F2a", "F1a", "visible", True),
        ("external_blocked", "F1a", "F2a", "visible", False),
        ("sibling_downward", "F1", "F2", "downward", False),
        ("unselected_parent_shortcut", "F0", "G1", "downward", False),
    ]
    data["queries"] = [{"id": i, "origin": o, "target": t, "mode": m, "expected": e}
                       for i, o, t, m, e in rows]
    return data


def oracle(data):
    hierarchy = nx.DiGraph()
    hierarchy.add_nodes_from(data["nodes"])
    # Keep normalization independent of the rustworkx/Cozo projection helper.
    # Literal expected Child rows additionally catch shared direction mistakes.
    for authored in data["relations"]:
        if all(authored[k] == v for k, v in data["hierarchy"].items()):
            owner, target = authored["owner"], authored["target"]
            if authored["kind"] == "Child":
                hierarchy.add_edge(owner, target)
            else:
                assert authored["kind"] == "Parent"
                hierarchy.add_edge(target, owner)
    assert nx.is_directed_acyclic_graph(hierarchy)
    assert all(hierarchy.in_degree(n) <= 1 for n in hierarchy)
    answers = {}
    for q in data["queries"]:
        origin, target = q["origin"], q["target"]
        graph = hierarchy if q["mode"] == "downward" else hierarchy.to_undirected()
        try:
            path = nx.shortest_path(graph, origin, target)
        except nx.NetworkXNoPath:
            answers[q["id"]] = False
            continue
        answers[q["id"]] = all(
            not hierarchy.has_edge(a, b) or not data["nodes"][a]["closed"]
            or nx.has_path(hierarchy, a, origin)
            for a, b in zip(path, path[1:])
        )
    return answers


def rustworkx(data):
    hierarchy = rx.PyDiGraph()
    ids = {n: hierarchy.add_node(n) for n in data["nodes"]}
    hierarchy.add_edges_from([(ids[p], ids[c], None) for p, c in selected_edges(data)])
    result = {}
    for q in data["queries"]:
        origin = ids[q["origin"]]
        inside = set(rx.ancestors(hierarchy, origin)) | {origin}
        adjacency = rx.PyDiGraph()
        adjacency.add_nodes_from(data["nodes"])
        for p, c in hierarchy.edge_list():
            if q["mode"] == "visible":
                adjacency.add_edge(c, p, None)
            if not data["nodes"][hierarchy[p]]["closed"] or p in inside:
                adjacency.add_edge(p, c, None)
        target = ids[q["target"]]
        result[q["id"]] = origin == target or rx.has_path(adjacency, origin, target)
    return result


def cozo(data):
    db = CozoDbPy("mem", "", "{}")
    params = {"nodes": [[n, v["closed"]] for n, v in data["nodes"].items()],
              "edges": [list(e) for e in selected_edges(data)],
              "queries": [[q[k] for k in ["id", "origin", "target", "mode"]]
                          for q in data["queries"]]}
    rows = db.run_script((SCRIPTS / "traversal.cozo").read_text(), params, True)["rows"]
    yes = {r[0] for r in rows}
    db.close()
    return {q["id"]: q["id"] in yes for q in data["queries"]}


def opa_result(data):
    proc = subprocess.run([str(ROOT / "opa"), "eval", "--strict-builtin-errors",
                           "--format=json", "--stdin-input", "--data",
                           str(SCRIPTS / "policy.rego"), "data.gate2.result"],
                          input=json.dumps(data), capture_output=True, text=True, timeout=30)
    if proc.returncode:
        raise RuntimeError(proc.stdout + proc.stderr)
    return json.loads(proc.stdout)["result"][0]["expressions"][0]["value"]


def opa(data):
    return opa_result(data)["answers"]


def compare(name, data, results, explicit=False):
    expected = oracle(data)
    if explicit:
        assert expected == {q["id"]: q["expected"] for q in data["queries"]}
    for backend in [rustworkx, cozo, opa]:
        start = time.perf_counter()
        actual = backend(data)
        elapsed = (time.perf_counter() - start) * 1000
        assert actual == expected, (name, backend.__name__, actual, expected)
        print(name, backend.__name__, round(elapsed, 3), flush=True)
        results.append({"case": name, "backend": backend.__name__,
                        "milliseconds": elapsed, "answers": actual})


def run():
    results = []
    original = base()
    (ROOT / "results" / "neutral-input.json").write_text(json.dumps(original, indent=2)+"\n")
    compare("base", original, results, explicit=True)
    child = child_base()
    (ROOT / "results" / "child-input.json").write_text(json.dumps(child, indent=2)+"\n")
    compare("selected_child_base", child, results, explicit=True)
    child_opened = copy.deepcopy(child)
    child_opened["nodes"]["F2"]["closed"] = False
    for query in child_opened["queries"]:
        if query["id"] in {"blocked_interior", "external_blocked"}:
            query["expected"] = True
    compare("selected_child_open_boundary", child_opened, results, explicit=True)
    opened = copy.deepcopy(original)
    opened["nodes"]["F2"]["closed"] = False
    compare("open_boundary_rechecks_unchanged_queries", opened, results)
    assert oracle(opened)["blocked_interior"]
    nested = copy.deepcopy(original)
    nested["nodes"]["F2a1"] = {"closed": False}
    nested["nodes"]["F2a"]["closed"] = True
    nested["relations"].append(relation("F2a1", "F2a"))
    nested["queries"] = [{"id": "nested_block", "origin": "F2b", "target": "F2a1", "mode": "visible", "expected": False}]
    compare("nested_boundary_from_internal_origin", nested, results, explicit=True)
    for key, value in [("model", "other-model"), ("owner_type", "other-type"),
                       ("kind", "Child"), ("role", "other-role")]:
        data = copy.deepcopy(original)
        data["relations"].append(relation("G1", "F0", **{key: value}))
        compare("selector_context_" + key, data, results, explicit=True)
    moved = copy.deepcopy(original)
    moved["relations"] = [r for r in moved["relations"] if r["owner"] != "F2a"]
    moved["relations"].append(relation("F2a", "F1"))
    compare("subtree_move", moved, results)
    assert oracle(moved)["blocked_interior"]

    # Ownership is retained in payload; direction is normalized separately.
    authored = [relation("A", "B"), relation("Z", "A", role="R"),
                relation("Z", "B", kind="Child", role="Q")]
    graph = rx.PyDiGraph()
    ids = {n: graph.add_node(n) for n in ["A", "B", "Z"]}
    for r in authored:
        p, c = (r["target"], r["owner"]) if r["kind"] == "Parent" else (r["owner"], r["target"])
        graph.add_edge(ids[p], ids[c], r)
    assert not rx.is_directed_acyclic_graph(graph)
    assert graph.get_edge_data(ids["Z"], ids["B"])["owner"] == "Z"
    results.append({"case": "mixed_role_cycle", "backend": "rustworkx",
                    "cycle": [[graph[a], graph[b]] for a,b in rx.digraph_find_cycle(graph)]})

    protected = copy.deepcopy(original)
    protected["snapshot"] = {"id": "protected-1", "records": {"I0": {"closed": False}}}
    protected["projection"] = {"I0": {"closed": False}}
    unchanged_result = opa_result(protected)
    assert unchanged_result["protected_changes"] == []
    assert unchanged_result["snapshot"] == "protected-1"
    protected["projection"] = {"I0": {"closed": True}}
    changed_result = opa_result(protected)
    assert changed_result["protected_changes"] == ["I0"]
    assert changed_result["snapshot"] == unchanged_result["snapshot"]
    assert opa_result(original)["protected_changes"] == []
    frozen = copy.deepcopy(protected)
    protected["snapshot"] = {"id": "empty-2", "records": {}}
    assert opa_result(frozen)["protected_changes"] == ["I0"]
    assert opa_result(protected)["protected_changes"] == []
    results.append({"case": "external_snapshot_change", "backend": "opa",
                    "captured_old_rejects": True, "new_empty_accepts": True,
                    "same_nonempty_snapshot": "protected-1",
                    "unchanged_protected_changes": unchanged_result["protected_changes"],
                    "changed_protected_changes": changed_result["protected_changes"]})

    # Actual database transaction tests, with an independent visible read.
    db = CozoDbPy("mem", "", "{}")
    db.run_script(":create value {id: Int => n: Int}", {}, False)
    db.run_script("?[id,n] <- [[1,10]] :put value {id => n}", {}, False)
    tx = db.multi_transact(True)
    tx.run_script("?[id,n] <- [[1,20]] :put value {id => n}", {})
    assert tx.run_script("?[id,n] := *value{id,n}", {})["rows"] == [[1,20]]
    tx.abort()
    assert db.run_script("?[id,n] := *value{id,n}", {}, True)["rows"] == [[1,10]]
    tx = db.multi_transact(True)
    tx.run_script("?[id,n] <- [[1,30]] :put value {id => n}", {})
    tx.commit()
    assert db.run_script("?[id,n] := *value{id,n}", {}, True)["rows"] == [[1,30]]
    results.append({"case": "sidecar_transaction", "backend": "cozo",
                    "staged_read_your_writes": True, "abort_restores": True, "commit_visible": True,
                    "independent_read_during_write": "blocked beyond 10 seconds; experiment killed at 20 seconds",
                    "scribe_files_git_atomic": "NOT TESTED; NOT PROVIDED"})
    db.register_fixed_rule("ConsumerSum", 1, lambda inputs, options: [[sum(row[0] for row in inputs[0])]])
    aggregate = db.run_script("v[n] <- [[2],[3]] ?[] <~ ConsumerSum(v[])", {}, True)
    assert aggregate["rows"] == [[5]]
    def failure(inputs, options):
        raise RuntimeError("deliberate consumer provider failure")
    db.register_fixed_rule("ConsumerFailure", 1, failure)
    try:
        db.run_script("v[n] <- [[2]] ?[] <~ ConsumerFailure(v[])", {}, True)
        raise AssertionError("failed callback was accepted")
    except Exception as exc:
        assert "deliberate consumer provider failure" in str(exc), str(exc)
    results.append({"case": "public_custom_fixed_rule", "backend": "cozo",
                    "sum": aggregate["rows"], "callback_error_propagated": True})
    db.close()

    versions = {p: importlib.metadata.version(p) for p in ["cozo-embedded", "networkx", "rustworkx"]}
    (ROOT / "results" / "finalists.json").write_text(json.dumps({"evidence_version": 2, "versions": versions, "results": results}, indent=2)+"\n")
    print(json.dumps({"versions": versions, "comparisons": len(results), "status": "pass"}, indent=2))


if __name__ == "__main__":
    run()
