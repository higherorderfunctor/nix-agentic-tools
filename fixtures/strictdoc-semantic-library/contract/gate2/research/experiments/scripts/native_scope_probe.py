"""Call native graph/detector APIs with default vs explicit role selection."""

import json
from pathlib import Path

from strictdoc.backend.sdoc.errors.document_tree_error import DocumentTreeError
from strictdoc.backend.sdoc.models.node import SDocNode
from strictdoc.backend.sdoc.reader import SDReader
from strictdoc.core.graph.abstract_bucket import ALL_EDGES
from strictdoc.core.graph.many_to_many_set import ManyToManySet
from strictdoc.core.graph_database import GraphDatabase
from strictdoc.core.tree_cycle_detector import TreeCycleDetector

ROOT = Path(__file__).resolve().parents[1]
document = SDReader.read((ROOT / "native/combined_role_cycle/input.sdoc").read_text())
nodes = {node.reserved_uid: node for node in document.section_contents}
graph = GraphDatabase([("children", ManyToManySet(SDocNode, SDocNode))])
for owner in nodes.values():
    for ref in owner.relations:
        target = nodes[ref.ref_uid]
        parent, child = (target, owner) if ref.ref_type == "Parent" else (owner, target)
        graph.create_link(link_type="children", lhs_node=parent, rhs_node=child, edge=ref.role)

rows = []
for selector in [None, ALL_EDGES]:
    def links(uid):
        return [node.reserved_uid for node in graph.get_link_values(
            link_type="children", lhs_node=nodes[uid], edge=selector)]
    detector = TreeCycleDetector()
    rejected = False
    witness = []
    try:
        for uid in nodes:
            detector.check_node(uid, links)
    except DocumentTreeError as error:
        rejected = True
        witness = error.cycled_uids
    assert rejected == (selector == ALL_EDGES)
    rows.append({"edge_selector": selector, "adjacency": {uid: links(uid) for uid in nodes},
                 "cycle_rejected": rejected, "witness": witness})
(ROOT / "results/native-scope.json").write_text(json.dumps(rows, indent=2)+"\n")
print(json.dumps(rows, indent=2))
