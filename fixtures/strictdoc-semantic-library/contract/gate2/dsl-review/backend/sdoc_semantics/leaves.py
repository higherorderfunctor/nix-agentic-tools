"""The seven named leaf kinds (contract.md:237-245).

One function per kind, each taking (context, leaf, subject) and returning the
leaf result triple {"status", "code", "evidence"} and nothing else. A leaf
never returns error, because error belongs to rule or envelope input,
configuration and execution handling (contract.md:587-588). A leaf never
builds a finding either: the caller owns uid, occurrence, occurrenceIndex,
predicatePath, kind and message.

The dispatch table LEAVES maps a kind to its function so the engine does no
branching of its own.

Subjects arrive as {"uid", "record", "occurrence", "occurrenceIndex"}, with all
of uid, occurrence and occurrenceIndex null for the model subject. The
evaluation context is documented in visibility.py, which is also where the
shared context adapter lives.
"""

from . import findings, graphs, visibility

# The closed compare space, kept in the contract's displayed order rather than
# alphabetical, because that order is what defines the meanings
# (contract.md:776, contract.md:783-784).
COMPARISONS = {
    "lt": lambda count, value: count < value,
    "lte": lambda count, value: count <= value,
    "gt": lambda count, value: count > value,
    "gte": lambda count, value: count >= value,
    "eq": lambda count, value: count == value,
}

# Evidence a blocked leaf carries alongside its own leaf evidence
# (contract.md:639). No leaf here is ever blocked by an external input or by a
# prerequisite, so the input id is always null and the prerequisite list empty.
NO_INPUT = None
NO_REQUIRES = []


# ---------------------------------------------------------------------------
# target-type
# ---------------------------------------------------------------------------


def target_type(context, leaf, subject):
    """Resolve the target uid and compare its element (contract.md:239)."""
    occurrence = subject.get("occurrence") or {}
    uid = occurrence.get("target")
    expected = visibility.declaration_name(context, leaf.get("targetElement"))
    record = visibility.record_of(context, uid)
    if record is None:
        evidence = findings.blocked_evidence(
            {"expectedElement": expected, "actualElement": None},
            visibility.UNRESOLVED_TARGET_REASON,
            NO_INPUT,
            list(NO_REQUIRES),
        )
        return _result("blocked", "unresolved-target", evidence)
    actual = record.get("element")
    status = "satisfied" if actual == expected else "violated"
    return _result(
        status, "target-type", {"expectedElement": expected, "actualElement": actual}
    )


# ---------------------------------------------------------------------------
# count
# ---------------------------------------------------------------------------


def count(context, leaf, subject):
    """Count every matching owned occurrence, then compare.

    Duplicates and zero count as authored and no endpoint has to resolve
    (contract.md:240, contract.md:259).
    """
    record = subject.get("record") or {}
    selected = _selected_occurrences(record, leaf.get("relation") or {})
    compare = leaf.get("compare")
    value = leaf.get("value")
    holds = COMPARISONS.get(compare)
    if holds is None:
        raise ValueError("The count leaf carries an unsupported compare %r." % (compare,))
    total = len(selected)
    evidence = {
        "occurrences": _indexed(record, selected),
        "count": total,
        "compare": compare,
        "value": value,
    }
    status = "satisfied" if holds(total, value) else "violated"
    return _result(status, "count", evidence)


def _selected_occurrences(record, relation):
    """Owned occurrences matching a direction and role, with their true index.

    The index is the position in the owner's full relations array, never a
    position in this filtered list (contract.md:613-616).
    """
    direction = relation.get("direction")
    role = relation.get("role")
    return [
        (position, occurrence)
        for position, occurrence in enumerate(record.get("relations") or [])
        if occurrence.get("direction") == direction and occurrence.get("role") == role
    ]


def _indexed(record, selected):
    return [
        findings.indexed_occurrence(record.get("uid"), position, occurrence)
        for position, occurrence in selected
    ]


# ---------------------------------------------------------------------------
# visible-target and endpoint-path
# ---------------------------------------------------------------------------


def visible_target(context, leaf, subject):
    """Walk from the owner to the target, keeping the origin fixed."""
    occurrence = subject.get("occurrence") or {}
    origin = _named_endpoint(leaf, "from", "owner", subject.get("uid"))
    target = _named_endpoint(leaf, "to", "target", occurrence.get("target"))
    policy = visibility.view_config(context, leaf.get("view"))
    outcome = visibility.walk(context, policy, origin, target, kind="visible-target")
    return _dressed(outcome, {"origin": origin, "target": target})


def _named_endpoint(leaf, key, allowed, uid):
    """Honour the closed from and to keyword spaces (contract.md:774-775)."""
    named = leaf.get(key, allowed)
    if named != allowed:
        raise ValueError("The visible-target leaf carries %s %r." % (key, named))
    return uid


def endpoint_path(context, leaf, subject):
    """Select each sole endpoint occurrence and walk downward between them."""
    record = subject.get("record") or {}
    upper = _selected_occurrences(record, leaf.get("upper") or {})
    lower = _selected_occurrences(record, leaf.get("lower") or {})
    base = {"upper": _indexed(record, upper), "lower": _indexed(record, lower)}
    if len(upper) != 1 or len(lower) != 1:
        return _not_singleton(record, base, upper, lower)
    origin = upper[0][1].get("target")
    target = lower[0][1].get("target")
    base["origin"] = origin
    base["target"] = target
    policy = visibility.view_config(context, leaf.get("view"))
    outcome = visibility.walk(
        context,
        policy,
        origin,
        target,
        kind="endpoint-path",
        require_descent=True,
        origin_label="upper",
        target_label="lower",
    )
    return _dressed(outcome, base)


def _not_singleton(record, base, upper, lower):
    """Refuse a non-singleton endpoint rather than pick an occurrence.

    Missing or multiple endpoints violate the standalone count rule and block
    endpoint selection; never select an arbitrary occurrence
    (contract.md:754-756). Unusable selections report null endpoints
    (contract.md:635).
    """
    label = "upper" if len(upper) != 1 else "lower"
    total = len(upper) if label == "upper" else len(lower)
    reason = (
        "Record %s owns %d %s endpoint occurrences rather than one, so no endpoint may be selected."
        % (record.get("uid"), total, label)
    )
    evidence = dict(base)
    evidence.update(
        {
            "origin": None,
            "target": None,
            "path": [],
            "walkedPath": [],
            "boundary": None,
        }
    )
    evidence = findings.blocked_evidence(
        evidence, reason, NO_INPUT, list(NO_REQUIRES)
    )
    return _result("blocked", "singleton", evidence)


def _dressed(outcome, base):
    """Turn a policy-walk outcome into a leaf result."""
    evidence = dict(base)
    evidence["path"] = outcome["path"]
    evidence["walkedPath"] = outcome["walkedPath"]
    evidence["boundary"] = outcome["boundary"]
    if outcome["status"] == "blocked":
        # The record and field of an unusable needed value are the further
        # details the blocked evidence row allows (contract.md:639), and they
        # are what lets the engine cite the exact envelope finding.
        extra = {
            name: outcome[name]
            for name in ("field", "record")
            if outcome.get(name) is not None
        }
        evidence = findings.blocked_evidence(
            evidence, outcome["reason"], NO_INPUT, list(NO_REQUIRES), extra
        )
    return _result(outcome["status"], outcome["code"], evidence)


# ---------------------------------------------------------------------------
# native-dag and forest-validity
# ---------------------------------------------------------------------------


def native_dag(context, leaf, subject):
    """Any directed cycle over all authored edges violates (contract.md:243).

    An unresolved target uid is an input error and blocks this leaf rather than
    violating it (contract.md:256-257).
    """
    model = visibility.model_of(context)
    unresolved = _dangling_pairs(model)
    if unresolved:
        evidence = findings.blocked_evidence(
            {"cycles": []},
            visibility.UNRESOLVED_TARGET_REASON,
            NO_INPUT,
            list(NO_REQUIRES),
        )
        return _result("blocked", "unresolved-target", evidence, unresolved)
    witnesses = [
        _cycle_witness(found)
        for found in graphs.find_cycles(graphs.native_edges(model), model) or []
    ]
    if witnesses:
        return _result("violated", "cycle", {"cycles": witnesses})
    return _result("satisfied", "native-dag", {"cycles": []})


def forest_validity(context, leaf, subject):
    """Require acyclicity, single incoming edges and in-view endpoints.

    A dangling endpoint of the view's own edges relation blocks this leaf
    (contract.md:256-258). A dangling occurrence of any other relation does
    not: the corpus measures that at
    backend/fixtures/deleted-target-leaves-dangling-reference/results.json,
    where an unresolved R target blocks native-dag and leaves H-forest
    satisfied.
    """
    model = visibility.model_of(context)
    config = visibility.view_config(context, leaf.get("view"))
    forest = graphs.build_forest(
        model, config, visibility.context_value(context, "declarations")
    )
    if forest.get("dangling"):
        evidence = findings.blocked_evidence(
            {"violations": []},
            visibility.UNRESOLVED_TARGET_REASON,
            NO_INPUT,
            list(NO_REQUIRES),
        )
        needed = [(uid, index) for uid, index, _ in forest["dangling"]]
        return _result("blocked", "unresolved-target", evidence, needed)
    witnesses = [
        _violation_witness(found) for found in graphs.forest_violations(forest) or []
    ]
    status = "violated" if witnesses else "satisfied"
    return _result(status, "forest-validity", {"violations": witnesses})


def _dangling_pairs(model):
    """Every authored occurrence whose target does not resolve.

    Returned as ``(uid, occurrenceIndex)`` pairs in candidate record order,
    because the native graph is built from every role and every element
    (contract.md:243) and therefore needs all of them resolved. The model
    preparation step already recorded them under exactly that key; the scan is
    the fallback for a model handed over without that table.
    """
    recorded = model.get("dangling")
    if isinstance(recorded, dict):
        return list(recorded)
    found = []
    by_uid = model.get("by_uid") or {}
    for record in model.get("records") or []:
        for index, occurrence in enumerate(record.get("relations") or []):
            if occurrence.get("target") not in by_uid:
                found.append((record.get("uid"), index))
    return found


def _cycle_witness(found):
    """Dress one cycle as {"cycle", "edges"} (contract.md:636)."""
    if isinstance(found, dict):
        edges = [_edge_witness(edge) for edge in found.get("edges") or []]
        walk = found.get("cycle")
        if walk is None:
            walk = found.get("walk") or found.get("vertices")
        if walk is None:
            walk = _closed_walk(edges)
        return {"cycle": list(walk), "edges": edges}
    edges = [_edge_witness(edge) for edge in found or []]
    return {"cycle": _closed_walk(edges), "edges": edges}


def _closed_walk(edges):
    """Recover the closed uid walk from an ordered edge list.

    A parent occurrence is an edge from the target to the owner and a child
    occurrence from the owner to the target (contract.md:253-255), so the walk
    is each edge's source in turn, closed by repeating the first one.
    """
    walk = [_edge_source(edge) for edge in edges]
    if walk:
        walk.append(walk[0])
    return walk


def _edge_source(edge):
    if edge.get("direction") == "parent":
        return edge.get("target")
    return edge.get("owner")


def _edge_witness(edge):
    """A graph witness edge: an indexed occurrence plus the owner's uid."""
    if not isinstance(edge, dict):
        raise ValueError("A graph witness edge is not an object: %r" % (edge,))
    return {
        "owner": _member(edge, "owner", "uid", "owner_uid", "ownerUid"),
        "occurrenceIndex": _member(
            edge, "occurrenceIndex", "occurrence_index", "index"
        ),
        "role": _member(edge, "role"),
        "direction": _member(edge, "direction", "nativeType", "native_type"),
        "target": _member(edge, "target"),
    }


def _member(source, *names):
    for name in names:
        if name in source:
            return source[name]
    return None


def _violation_witness(found):
    """Dress one forest violation in whichever of its three shapes it is."""
    if not isinstance(found, dict):
        raise ValueError("A forest violation is not an object: %r" % (found,))
    if "cycle" in found or "walk" in found or "edges" in found:
        return _cycle_witness(found)
    if "parents" in found:
        return {
            "uid": found.get("uid"),
            "parents": [_edge_witness(parent) for parent in found.get("parents") or []],
        }
    occurrence = found.get("occurrence") if isinstance(found.get("occurrence"), dict) else found
    witness = _edge_witness(occurrence)
    witness["expectedElement"] = _member(found, "expectedElement", "expected_element")
    witness["actualElement"] = _member(found, "actualElement", "actual_element")
    return witness


# ---------------------------------------------------------------------------
# preserve
# ---------------------------------------------------------------------------


def preserve(context, leaf, subject):
    """Compare every baseline-listed uid with the defaulted candidate.

    The comparison covers existence, element, the projection's listed fields as
    presence and value objects compared as native strings, and its listed owned
    relations as duplicate-free triple sets (contract.md:342-357).
    """
    model = visibility.model_of(context)
    snapshot = visibility.snapshot_of(context, leaf.get("baseline"))
    projection = visibility.declared(context, "projections", leaf.get("projection"))
    config = {}
    if isinstance(projection, dict):
        config = projection.get("config")
        if not isinstance(config, dict):
            config = projection
    if not isinstance(snapshot, dict):
        evidence = findings.blocked_evidence(
            {"baseline": None, "differences": []},
            "The baseline snapshot for %s was never captured." % (leaf.get("baseline"),),
            leaf.get("baseline"),
            list(NO_REQUIRES),
        )
        return _result("blocked", "input", evidence)
    differences = _preservation_differences(context, model, snapshot, config)
    evidence = {"baseline": snapshot.get("identity"), "differences": differences}
    if differences:
        return _result("violated", "difference", evidence)
    return _result("satisfied", "preserve", evidence)


def _preservation_differences(context, model, snapshot, config):
    """Differences in baseline record order, components in a fixed sequence."""
    by_uid = model.get("by_uid") or {}
    differences = []
    for protected in snapshot.get("records") or []:
        uid = protected.get("uid")
        candidate = by_uid.get(uid)
        if candidate is None:
            if config.get("existence"):
                differences.append(_difference(uid, "existence", True, False))
            continue
        if config.get("element"):
            before = protected.get("element")
            after = candidate.get("element")
            if before != after:
                differences.append(_difference(uid, "element", before, after))
        for field_id in config.get("fields") or []:
            found = _field_difference(context, protected, candidate, field_id)
            if found is not None:
                differences.append(found)
        for relation_id in config.get("ownedRelations") or []:
            found = _relation_difference(context, protected, candidate, relation_id)
            if found is not None:
                differences.append(found)
    return differences


def _difference(uid, component, before, after):
    return {"uid": uid, "component": component, "before": before, "after": after}


def _field_difference(context, protected, candidate, field_id):
    """A field declaration only selects records of its owner element."""
    declaration = visibility.declared(context, "declarations", field_id)
    if not isinstance(declaration, dict):
        return None
    owner = visibility.declaration_name(context, declaration.get("owner"))
    if owner is not None and protected.get("element") != owner:
        return None
    name = declaration.get("name")
    before = _presence(protected, name)
    after = _presence(candidate, name)
    if before == after:
        return None
    return _difference(protected.get("uid"), field_id, before, after)


def _presence(record, name):
    """Distinguish an absent key from every present list (contract.md:347)."""
    fields = record.get("fields") or {}
    if name not in fields:
        return {"present": False, "values": []}
    return {"present": True, "values": list(fields.get(name) or [])}


def _relation_difference(context, protected, candidate, relation_id):
    """Compare one owned relation as a duplicate-free set of triples."""
    declaration = visibility.declared(context, "declarations", relation_id)
    if not isinstance(declaration, dict):
        return None
    owner = visibility.declaration_name(context, declaration.get("owner"))
    if owner is not None and protected.get("element") != owner:
        return None
    direction = declaration.get("direction")
    role = declaration.get("name")
    before = _triples(protected, direction, role)
    after = _triples(candidate, direction, role)
    if before == after:
        return None
    return _difference(protected.get("uid"), relation_id, before, after)


def _triples(record, direction, role):
    """Unique direction, role and target triples in a settled order.

    relationOrder set removes ordering and identical duplicates from this
    comparison only (contract.md:352-353), so the presentation order is chosen
    here: ascending by direction, then role, then target.
    """
    unique = {
        (occurrence.get("direction"), occurrence.get("role"), occurrence.get("target"))
        for occurrence in record.get("relations") or []
        if occurrence.get("direction") == direction and occurrence.get("role") == role
    }
    return [
        {"direction": triple[0], "role": triple[1], "target": triple[2]}
        for triple in sorted(unique)
    ]


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def _result(status, code, evidence, blocking=None):
    """Build a leaf result, optionally naming the resolutions it needed.

    ``blocking`` is the list of ``(uid, occurrenceIndex)`` pairs whose
    unresolved targets made this leaf unevaluable. Only the leaf knows which
    occurrences its own algorithm reads, and the entry's ``causes`` must cite
    the envelope finding for each resolution the rule needs and no other
    (contract.md:460-465), so the leaf states them rather than leaving the
    engine to guess from evidence.
    """
    result = {"status": status, "code": code, "evidence": evidence}
    if blocking is not None:
        result["blocking"] = [(uid, index) for uid, index in blocking]
    return result


LEAVES = {
    "count": count,
    "endpoint-path": endpoint_path,
    "forest-validity": forest_validity,
    "native-dag": native_dag,
    "preserve": preserve,
    "target-type": target_type,
    "visible-target": visible_target,
}
