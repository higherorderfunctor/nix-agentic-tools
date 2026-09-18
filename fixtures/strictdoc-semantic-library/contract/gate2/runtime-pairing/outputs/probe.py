"""Mechanical, synthetic graph probe; no semantic adapter or Scribe access."""
import importlib.metadata
import json
import platform
import sys

import strictdoc
from strictdoc.cli.main import main  # Exercise the installed CLI import dependencies.
import rustworkx as rx

assert platform.python_version() == "3.14.6"
assert importlib.metadata.version("strictdoc") == "0.28.3"
assert rx.__version__ == "0.17.1"
# Normalize synthetic declarations to parent -> child, with equivalent spellings.
declarations = [("B", "Parent", "A"), ("A", "Child", "B"), ("B", "Child", "C")]
edges = {(target, source) if kind == "Parent" else (source, target)
         for source, kind, target in declarations}
assert edges == {("A", "B"), ("B", "C")}
graph = rx.PyDiGraph(multigraph=False)
indices = {name: graph.add_node(name) for name in ("A", "B", "C", "isolated")}
for parent, child in sorted(edges):
    graph.add_edge(indices[parent], indices[child], None)
assert graph.num_edges() == 2
assert rx.is_directed_acyclic_graph(graph)
paths = list(rx.all_simple_paths(graph, indices["A"], indices["C"]))
assert paths == [[indices["A"], indices["B"], indices["C"]]]
assert not list(rx.all_simple_paths(graph, indices["C"], indices["A"]))
assert not list(rx.all_simple_paths(graph, indices["A"], indices["isolated"]))
graph.add_edge(indices["C"], indices["A"], None)
assert not rx.is_directed_acyclic_graph(graph)
assert list(rx.digraph_find_cycle(graph))
print(json.dumps({"status": "passed", "python": platform.python_version(),
                  "executable": sys.executable, "strictdoc": importlib.metadata.version("strictdoc"),
                  "strictdoc_module": strictdoc.__file__, "rustworkx": rx.__version__,
                  "rustworkx_module": rx.__file__, "normalized_edges": sorted(edges),
                  "path": [graph[i] for i in paths[0]], "controls":
                  ["acyclic graph", "reverse unreachable", "isolated unreachable", "cycle detected"]}, indent=2))
