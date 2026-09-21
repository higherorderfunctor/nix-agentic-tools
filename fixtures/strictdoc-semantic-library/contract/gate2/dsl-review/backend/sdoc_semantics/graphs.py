"""All graph work, standard library only.

An edge is a dict with five members, so a witness can be dressed without going
back to the model:

    source        the uid the edge comes from
    destination   the uid the edge points to
    owner         the uid of the record owning the occurrence
    index         the occurrenceIndex inside that owner's full relations array
    occurrence    the occurrence dict itself

The one orientation rule is contract.md:253-255: a parent occurrence is an edge
target to owner, a child occurrence owner to target. A selected forest declaring
``orientation: parent-to-child`` therefore needs no second rule, because that
rule already puts the parent at the source.
"""

from . import findings as findings_module
from .loading import ConfigurationError
from .model import records_of


def edge_from_occurrence(record, index, occurrence):
    """Apply the orientation rule of contract.md:253-255 to one occurrence."""
    owner = record["uid"]
    target = occurrence["target"]
    if occurrence["direction"] == "parent":
        source, destination = target, owner
    else:
        source, destination = owner, target
    return {
        "source": source,
        "destination": destination,
        "owner": owner,
        "index": index,
        "occurrence": occurrence,
    }


def witness_edge(edge):
    """Dress one edge as a graph witness occurrence with its owner's uid."""
    return findings_module.indexed_occurrence(
        edge["owner"], edge["index"], edge["occurrence"], with_owner=True
    )


def native_edges(model):
    """Build the native edge set from every authored occurrence.

    Every role and every element contributes (contract.md:243). An occurrence
    whose target does not resolve is left out, because an unresolved target uid
    blocks the graph rules rather than contributing an edge
    (contract.md:256-258); the leaf reads ``model["dangling"]`` to see that.
    """
    edges = []
    for record in model["records"]:
        for index, occurrence in enumerate(record["relations"]):
            if occurrence["target"] not in model["by_uid"]:
                continue
            edges.append(edge_from_occurrence(record, index, occurrence))
    return edges


def place_of(model):
    """A function giving each uid its candidate record position."""
    positions = model["position"]
    unplaced = len(positions)

    def place(uid):
        return positions.get(uid, unplaced)

    return place


def find_cycles(edges, model):
    """Enumerate simple directed cycles, self-loops included.

    Each witness is rotated to begin at the cycle vertex earliest in candidate
    record order, that uid is repeated to close the walk, and the edges are
    listed in walk order, one per consecutive pair (contract.md:636,
    contract.md:616-618). Candidate record order is the contract's only stated
    ordering principle (contract.md:580-581), which is why it decides the
    rotation as well.

    Parallel identical edges do not create a directed cycle
    (contract.md:255-256), so enumeration runs over the unique ordered vertex
    pairs and each pair keeps the first edge in scan order as its witness.
    """
    place = place_of(model)
    first_edge = {}
    for edge in edges:
        pair = (edge["source"], edge["destination"])
        if pair not in first_edge:
            first_edge[pair] = edge
    following = {}
    for source, destination in first_edge:
        following.setdefault(source, []).append(destination)
    for source in following:
        following[source].sort(key=place)
    vertices = set()
    for source, destination in first_edge:
        vertices.add(source)
        vertices.add(destination)

    walks = []
    for start in sorted(vertices, key=place):
        collect_walks(start, place(start), following, place, [start], {start}, walks)
    walks.sort(key=lambda walk: tuple(place(uid) for uid in walk))

    witnesses = []
    for walk in walks:
        closed = list(walk) + [walk[0]]
        pairs = list(zip(closed, closed[1:]))
        witnesses.append(
            {
                "cycle": closed,
                "edges": [witness_edge(first_edge[pair]) for pair in pairs],
            }
        )
    return witnesses


def collect_walks(start, limit, following, place, walk, on_walk, walks):
    """Depth-first walk that reports each simple cycle exactly once.

    Only a vertex later than the start in candidate record order may extend the
    walk, so every cycle is found from its earliest vertex and is therefore
    already rotated and never repeated under another rotation.
    """
    current = walk[-1]
    for step in following.get(current, ()):
        if step == start:
            walks.append(list(walk))
        elif step not in on_walk and place(step) > limit:
            walk.append(step)
            on_walk.add(step)
            collect_walks(start, limit, following, place, walk, on_walk, walks)
            walk.pop()
            on_walk.discard(step)


def build_forest(model, view_config, declarations):
    """Build a selected forest from a selected-forest/v1 view.

    Vertices are the records of the view's vertices element, isolated ones
    included, and edges are the occurrences of the view's edges relation
    (contract.md:294-298).

    ``view_config`` may be either the view declaration or its ``config``, so a
    caller that already resolved the declaration need not unwrap it.
    """
    if "config" in view_config and view_config.get("kind") == "view":
        view_config = view_config["config"]
    if view_config.get("contract") != "selected-forest/v1":
        raise ConfigurationError(
            "a forest needs a selected-forest/v1 view, not "
            + repr(view_config.get("contract"))
        )
    element = declarations["element_by_id"].get(view_config["vertices"])
    if element is None:
        raise ConfigurationError(
            "unknown forest vertices element " + str(view_config["vertices"])
        )
    relation = declarations["relation_by_id"].get(view_config["edges"])
    if relation is None:
        raise ConfigurationError(
            "unknown forest edges relation " + str(view_config["edges"])
        )
    owner_element = declarations["element_by_id"].get(relation["owner"])
    if owner_element is None:
        raise ConfigurationError(
            "the forest edges relation has no declared owner element"
        )
    vertex_element = element["name"]
    forest = {
        "view": view_config,
        "element": vertex_element,
        "relation": relation,
        "vertices": [record["uid"] for record in records_of(model, vertex_element)],
        "vertex_set": set(),
        "edges": [],
        "dangling": [],
        "wrong_endpoints": [],
        "incoming": {},
        "parent": {},
        "children": {},
        "model": model,
    }
    forest["vertex_set"] = set(forest["vertices"])
    for uid in forest["vertices"]:
        forest["incoming"][uid] = []
        forest["children"][uid] = []
    for record in records_of(model, owner_element["name"]):
        for index, occurrence in enumerate(record["relations"]):
            if occurrence["direction"] != relation["direction"]:
                continue
            if occurrence["role"] != relation["name"]:
                continue
            if occurrence["target"] not in model["by_uid"]:
                forest["dangling"].append((record["uid"], index, occurrence))
                continue
            edge = edge_from_occurrence(record, index, occurrence)
            forest["edges"].append(edge)
            outside = endpoint_outside(model, forest, edge)
            if outside is not None:
                forest["wrong_endpoints"].append((edge, outside))
                continue
            forest["incoming"].setdefault(edge["destination"], []).append(edge)
    for uid, edges in forest["incoming"].items():
        if len(edges) == 1:
            parent = edges[0]["source"]
            forest["parent"][uid] = parent
            forest["children"].setdefault(parent, []).append(uid)
    return forest


def endpoint_outside(model, forest, edge):
    """The resolved endpoint outside the selected vertex element, or None.

    A resolved forest endpoint outside that element violates forest validity
    (contract.md:257-259).
    """
    for uid in (edge["source"], edge["destination"]):
        if uid in forest["vertex_set"]:
            continue
        record = model["by_uid"].get(uid)
        if record is None:
            continue
        return record["element"]
    return None


def forest_violations(forest):
    """Report forest violations in three passes.

    Cycles first, then vertices with more than one incoming selected
    occurrence, then resolved endpoints outside the selected vertex element —
    the order the evidence row itself lists (contract.md:637,
    contract.md:244, contract.md:257-259).
    """
    model = forest["model"]
    place = place_of(model)
    violations = list(find_cycles(forest["edges"], model))
    cardinality = [
        (uid, edges)
        for uid, edges in forest["incoming"].items()
        if len(edges) > 1
    ]
    cardinality.sort(key=lambda row: place(row[0]))
    for uid, edges in cardinality:
        ordered = sorted(edges, key=lambda edge: (place(edge["owner"]), edge["index"]))
        violations.append(
            {
                "uid": uid,
                "parents": [witness_edge(edge) for edge in ordered],
            }
        )
    for edge, actual in forest["wrong_endpoints"]:
        witness = witness_edge(edge)
        witness["expectedElement"] = forest["element"]
        witness["actualElement"] = actual
        violations.append(witness)
    return violations


def parent_of(forest, uid):
    """The one selected parent of a vertex, or None for a root."""
    return forest["parent"].get(uid)


def ancestors(forest, uid):
    """The chain from a vertex up to its root, the vertex itself included."""
    chain = [uid]
    seen = {uid}
    step = parent_of(forest, uid)
    while step is not None and step not in seen:
        chain.append(step)
        seen.add(step)
        step = parent_of(forest, step)
    return chain


def lowest_common_ancestor(forest, left, right):
    """The nearest shared ancestor, or None when the roots differ."""
    upward = ancestors(forest, left)
    ranks = {uid: rank for rank, uid in enumerate(upward)}
    for uid in ancestors(forest, right):
        if uid in ranks:
            return uid
    return None


def structural_route(forest, origin, target):
    """The unique structural route between two vertices, or None.

    Visibility ascends to the nearest shared ancestor and then descends to the
    target (contract.md:303-304), so the route is the ascent from the origin up
    to that ancestor followed by the descent to the target. A zero-step route
    is the single-vertex list (contract.md:314-315).
    """
    if origin == target:
        return [origin]
    meeting = lowest_common_ancestor(forest, origin, target)
    if meeting is None:
        return None
    upward = ancestors(forest, origin)
    climb = upward[: upward.index(meeting) + 1]
    downward = ancestors(forest, target)
    descend = downward[: downward.index(meeting)]
    descend.reverse()
    return climb + descend


def subtree_contains(forest, node, candidate_uid):
    """Whether a vertex lies in a node's subtree, the node itself included."""
    return node in ancestors(forest, candidate_uid)
