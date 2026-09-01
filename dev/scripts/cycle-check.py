#!/usr/bin/env python3
# cspell:ignore uids
"""cycle-check -- MECH-CYCLE-CHECK. Cycle detection over the JSON export.

Usage: cycle-check.py <export.json>

StrictDoc's own cycle detection queries the graph database without
specifying an edge role, and the database returns only the bucket of
role-less edges. Every relation in this grammar carries a role (Governed_By,
Crosses, Guarantees, ...), so no cycle in this corpus is caught by it -- the
failure surfaces as a recursion-depth crash during render, not an error.

This walks every `Parent`-type relation regardless of role (`File`
relations point at filesystem paths, not nodes, and are excluded) and
reports every simple cycle found. Exit status is non-zero when any cycle is
found.

Generate the export first with a CLEAN output directory -- incremental
export produces false greens (see the sdoc skill's gotcha list):

    rm -rf output && strictdoc export . --formats=json --output-dir output
    dev/scripts/cycle-check.py output/json/index.json
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_fp import build_uid_index, iter_nodes, load_index


def build_graph(index: dict) -> dict:
    """UID -> list of (target_uid, role) for every Parent-type relation,
    regardless of role. File relations are excluded -- their VALUE names a
    filesystem path, not a node."""
    by_uid = build_uid_index(index)
    graph = {}
    for uid, node in by_uid.items():
        edges = [
            (r["VALUE"], r.get("ROLE", ""))
            for r in node.get("RELATIONS", [])
            if r.get("TYPE") == "Parent"
        ]
        graph[uid] = edges
    return graph


def _canonicalize(core: list) -> tuple:
    """Rotate a cycle's node list to start at its lexicographically smallest
    UID, so the same cycle found from different starting points dedupes to
    one report. Only rotation is considered -- the graph is directed, so a
    cycle and its reverse are different cycles (and the reverse would need
    its own back-edges to exist)."""
    min_idx = min(range(len(core)), key=lambda i: core[i])
    return tuple(core[min_idx:] + core[:min_idx])


def find_cycles(graph: dict) -> list:
    """Iterative DFS with an explicit stack, so this never hits the exact
    recursion-depth failure it exists to replace. WHITE = unvisited, GRAY =
    on the current path, BLACK = fully explored. A GRAY target closes a
    cycle; a BLACK target is a cross edge in the DAG sense and is not one."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {uid: WHITE for uid in graph}
    cycles = []
    seen = set()

    for start in graph:
        if color[start] != WHITE:
            continue
        color[start] = GRAY
        path = [start]
        frames = [iter(graph[start])]
        while frames:
            try:
                target, role = next(frames[-1])
            except StopIteration:
                color[path.pop()] = BLACK
                frames.pop()
                continue
            if target not in color:
                continue  # dangling reference; not this check's job
            if color[target] == WHITE:
                color[target] = GRAY
                path.append(target)
                frames.append(iter(graph[target]))
            elif color[target] == GRAY:
                idx = path.index(target)
                core = path[idx:]
                canon = _canonicalize(core)
                if canon not in seen:
                    seen.add(canon)
                    cycles.append(core + [target])
            # BLACK: already fully explored elsewhere, not part of a cycle here
    return cycles


def _role_between(graph: dict, u: str, v: str) -> str:
    for target, role in graph[u]:
        if target == v:
            return role
    return "?"  # unreachable: the edge that produced this pair came from graph


def format_cycle(graph: dict, cycle: list) -> str:
    hops = [f"{cycle[i]} --{_role_between(graph, cycle[i], cycle[i + 1])}-->" for i in range(len(cycle) - 1)]
    return " ".join(hops) + f" {cycle[-1]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    args = parser.parse_args()

    index = load_index(args.export_json)
    node_count = sum(1 for _ in iter_nodes(index))
    graph = build_graph(index)
    cycles = find_cycles(graph)

    if cycles:
        print(f"\n== cycles ({len(cycles)}) ==")
        for cycle in cycles:
            print(f"  {format_cycle(graph, cycle)}")

    edge_count = sum(len(edges) for edges in graph.values())
    print(f"\n{node_count} nodes, {edge_count} role-carrying edges checked: {len(cycles)} cycle(s) found")

    return 1 if cycles else 0


if __name__ == "__main__":
    sys.exit(main())
