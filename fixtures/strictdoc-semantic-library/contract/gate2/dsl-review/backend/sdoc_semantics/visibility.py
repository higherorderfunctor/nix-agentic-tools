"""The origin-sensitive-visibility/v1 policy walk (contract.md:298-315).

Both the visible-target and the endpoint-path leaf hand their boundary
semantics here, so the policy exists exactly once. The order of decisions is
fixed by contract.md:821-823: endpoints first, then shared root, then
direction, then the walk itself.

This module is also the home of the shared evaluation-context adapter, because
leaves.py imports visibility.py and the reverse import would close a cycle.
The context is whatever the engine hands a leaf. The members read here are:

    model           the record model built by model.build_model
    bundle          the decoded bundle file, holding bundle, grammar and
                    semanticTypes, used to resolve declaration and view ids
    declarations    the index built by loading.load_bundle
    snapshots       captured external inputs, keyed by input declaration id
    fieldProblems   native field validation problems, keyed by (uid, field
                    name) or by uid then field name, used so that a blocked
                    leaf repeats the envelope finding's own reason text
    forests         an optional cache of built forests, keyed by view id

Every member is read through context_value, which accepts a mapping key or an
attribute and tolerates a few spellings, so the engine may carry them in a
dictionary or in a small record object.
"""

from . import graphs

# The only visibility algorithm this profile has (contract.md:790-791). The
# forest contract is graphs.build_forest's own check, not repeated here.
VISIBILITY_CONTRACT = "origin-sensitive-visibility/v1"

UNRESOLVED_TARGET_REASON = (
    "The occurrence target does not resolve to a candidate record."
)
UNRESOLVED_OWNER_REASON = (
    "The occurrence owner does not resolve to a candidate record."
)

# The codec and choices used when a packet supplies no semantic metadata for
# the closing field. Only "false" and "true" decode (contract.md:970-972).
FALLBACK_CHOICES = ["false", "true"]
FALLBACK_CODEC = [
    {"native": "false", "semantic": False},
    {"native": "true", "semantic": True},
]


# ---------------------------------------------------------------------------
# Shared evaluation-context adapter
# ---------------------------------------------------------------------------


def context_value(context, *names):
    """Read the first present member of the context, by key or attribute."""
    for name in names:
        if isinstance(context, dict):
            if name in context:
                return context[name]
        else:
            value = getattr(context, name, None)
            if value is not None:
                return value
    return None


def model_of(context):
    """Return the record model the engine built for this candidate."""
    model = context_value(context, "model")
    if not isinstance(model, dict):
        raise ValueError("The evaluation context carries no record model.")
    return model


def record_of(context, uid):
    """Return the candidate record for a uid, or None when it is dangling."""
    model = model_of(context)
    by_uid = model.get("by_uid") or {}
    return by_uid.get(uid)


def declared(context, section, wanted_id):
    """Find a declaration by its id in one of the bundle's named sections.

    `section` is declarations, views, inputs or projections. Ids are opaque
    after indexing (contract.md:856), so this only ever compares them.

    The declarations index's own id maps answer first; the generic search over
    the bundle is the fallback for a context that carries the bundle alone.
    """
    if not wanted_id:
        return None
    indexed = _from_index(context, section, wanted_id)
    if indexed is not None:
        return indexed
    for container in _containers(context, section):
        found = _find_by_id(container, wanted_id)
        if found is not None:
            return found
    return None


# The declarations index's id maps, by the section a caller names. Declaration
# ids are looked up in the three kind maps because contract.md:787-789 keeps
# views, inputs and projections in their own named lists instead.
INDEX_MAPS = {
    "declarations": ("element_by_id", "field_by_id", "relation_by_id"),
    "inputs": ("inputs",),
    "projections": ("projections",),
    "views": ("views",),
}


def _from_index(context, section, wanted_id):
    index = context_value(context, "declarations", "index")
    if not isinstance(index, dict):
        return None
    for name in INDEX_MAPS.get(section, ()):
        table = index.get(name)
        if isinstance(table, dict) and isinstance(table.get(wanted_id), dict):
            return table[wanted_id]
    return None


def _containers(context, section):
    """Collect every place a declaration of this section might be indexed."""
    found = []
    for name in (section, "declarations", "index", "bundle", "packet"):
        value = context_value(context, name)
        if value is not None:
            found.append(value)
    nested = []
    for value in found:
        if not isinstance(value, dict):
            continue
        for name in (section, "bundle"):
            inner = value.get(name)
            if inner is None:
                continue
            nested.append(inner)
            if isinstance(inner, dict) and section in inner:
                nested.append(inner[section])
    return found + nested


def _find_by_id(container, wanted_id):
    """Return the entry whose id is wanted_id, from a mapping or a list."""
    if isinstance(container, dict):
        direct = container.get(wanted_id)
        if isinstance(direct, dict) and direct.get("id") == wanted_id:
            return direct
        for value in container.values():
            if isinstance(value, dict) and value.get("id") == wanted_id:
                return value
    if isinstance(container, (list, tuple)):
        for item in container:
            if isinstance(item, dict) and item.get("id") == wanted_id:
                return item
    return None


def declaration_name(context, declaration_id):
    """Return a declaration's name, which is what candidate records carry."""
    declaration = declared(context, "declarations", declaration_id)
    if isinstance(declaration, dict):
        return declaration.get("name")
    return None


def view_config(context, view_id):
    """Return a view declaration's config block."""
    view = declared(context, "views", view_id)
    if not isinstance(view, dict):
        raise ValueError("The bundle declares no view %s." % (view_id,))
    config = view.get("config")
    return config if isinstance(config, dict) else view


def snapshot_of(context, input_id):
    """Return the captured snapshot for an external input declaration."""
    table = context_value(context, "snapshots", "captured", "inputs")
    if not isinstance(table, dict):
        return None
    value = table.get(input_id)
    if isinstance(value, dict) and isinstance(value.get("snapshot"), dict):
        return value["snapshot"]
    return value if isinstance(value, dict) else None


def semantic_field(context, field_id):
    """Return the semanticTypes entry describing one field declaration."""
    types = context_value(context, "semanticTypes", "semantic_types")
    if types is None:
        bundle = context_value(context, "bundle", "packet")
        if isinstance(bundle, dict):
            types = bundle.get("semanticTypes")
    if not isinstance(types, (list, tuple)):
        return None
    for entry in types:
        if not isinstance(entry, dict):
            continue
        for field in entry.get("fields") or []:
            if isinstance(field, dict) and field.get("field") == field_id:
                return field
    return None


def recorded_problem(context, uid, field_name):
    """Return the preparation finding's reason for one record field.

    A blocked leaf repeats the reason the envelope finding already carries, so
    the two agree exactly; the corpus measures that agreement at
    backend/fixtures/no-backfill-on-existing-absent-field/results.json.
    """
    table = context_value(
        context,
        "fieldProblems",
        "field_problems",
        "fieldErrors",
        "field_errors",
    )
    if not isinstance(table, dict):
        return None
    pair = (uid, field_name)
    if pair in table:
        return _problem_reason(table[pair])
    owned = table.get(uid)
    if isinstance(owned, dict):
        return _problem_reason(owned.get(field_name))
    return None


def _problem_reason(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if isinstance(value.get("reason"), str):
            return value["reason"]
        evidence = value.get("evidence")
        if isinstance(evidence, dict) and isinstance(evidence.get("reason"), str):
            return evidence["reason"]
    return None


# ---------------------------------------------------------------------------
# The hierarchy the policy walks
# ---------------------------------------------------------------------------


def hierarchy(context, policy_config):
    """Return the normalized forest named by a visibility view's hierarchy.

    The result is {"id", "parent", "vertices", "raw"}. The parent map and the
    vertex set are what the ascent and descent steps need; `raw` is whatever
    graphs.build_forest produced, kept so its own route primitive can be
    offered a forest it recognizes.
    """
    if policy_config.get("contract") != VISIBILITY_CONTRACT:
        raise ValueError(
            "A policy walk needs a %s view, not %r."
            % (VISIBILITY_CONTRACT, policy_config.get("contract"))
        )
    hierarchy_id = policy_config.get("hierarchy")
    forest_config = view_config(context, hierarchy_id)
    raw = _built_forest(context, hierarchy_id, forest_config)
    parent, vertices = _forest_shape(raw)
    if not vertices:
        vertices = _vertices_from_model(context, forest_config)
    if not parent:
        parent = _parents_from_model(context, forest_config, vertices)
    return {
        "id": hierarchy_id,
        "parent": parent,
        "vertices": vertices,
        "raw": raw,
    }


def _built_forest(context, view_id, forest_config):
    cache = context_value(context, "forests", "forest_cache")
    if isinstance(cache, dict) and cache.get(view_id) is not None:
        return cache[view_id]
    try:
        return graphs.build_forest(
            model_of(context),
            forest_config,
            context_value(context, "declarations"),
        )
    except Exception:
        # The forest shape is not pinned by the contract, so a built forest is
        # an optimization here and the model is always enough to rebuild one.
        return None


def _forest_shape(raw):
    """Read a parent map and a vertex set out of a built forest."""
    parent = {}
    vertices = set()
    if not isinstance(raw, dict):
        return parent, vertices
    for name in ("parent", "parents", "parent_of", "parentOf"):
        table = raw.get(name)
        if not isinstance(table, dict):
            continue
        for child, value in table.items():
            chosen = value
            if isinstance(value, (list, tuple)):
                chosen = value[0] if value else None
            if isinstance(chosen, str):
                parent[child] = chosen
        break
    for name in ("vertices", "nodes", "members"):
        listed = raw.get(name)
        if isinstance(listed, dict):
            vertices.update(listed.keys())
            break
        if isinstance(listed, (list, tuple, set)):
            for item in listed:
                if isinstance(item, str):
                    vertices.add(item)
                elif isinstance(item, dict) and isinstance(item.get("uid"), str):
                    vertices.add(item["uid"])
            break
    return parent, vertices


def _vertices_from_model(context, forest_config):
    """Every record of the view's vertices element, isolated ones included."""
    element = declaration_name(context, forest_config.get("vertices"))
    model = model_of(context)
    return {
        record.get("uid")
        for record in model.get("records") or []
        if record.get("element") == element
    }


def _parents_from_model(context, forest_config, vertices):
    """Apply the orientation rule of contract.md:253-255 to selected edges."""
    relation = declared(context, "declarations", forest_config.get("edges"))
    if not isinstance(relation, dict):
        return {}
    owner = declaration_name(context, relation.get("owner"))
    direction = relation.get("direction")
    role = relation.get("name")
    parent = {}
    model = model_of(context)
    for record in model.get("records") or []:
        if record.get("element") != owner:
            continue
        uid = record.get("uid")
        for occurrence in record.get("relations") or []:
            if occurrence.get("direction") != direction:
                continue
            if occurrence.get("role") != role:
                continue
            target = occurrence.get("target")
            if uid not in vertices or target not in vertices:
                continue
            if direction == "parent":
                parent.setdefault(uid, target)
            else:
                parent.setdefault(target, uid)
    return parent


def ancestor_chain(forest, uid):
    """The uids from a vertex up to its root, the vertex itself first."""
    chain = [uid]
    seen = {uid}
    node = uid
    while True:
        above = forest["parent"].get(node)
        if above is None or above in seen:
            break
        chain.append(above)
        seen.add(above)
        node = above
    return chain


def structural_route(forest, origin, target):
    """The unique route between two vertices, or None across distinct roots."""
    offered = _offered_route(forest, origin, target)
    if offered is not None:
        return offered
    upward = ancestor_chain(forest, origin)
    downward = ancestor_chain(forest, target)
    if upward[-1] != downward[-1]:
        return None
    depth = {uid: position for position, uid in enumerate(downward)}
    for position, uid in enumerate(upward):
        if uid in depth:
            return upward[: position + 1] + list(reversed(downward[: depth[uid]]))
    return None


def _offered_route(forest, origin, target):
    """Use the route graphs computed, but only when it is verifiably adjacent."""
    if forest.get("raw") is None:
        return None
    try:
        offered = graphs.structural_route(forest["raw"], origin, target)
    except Exception:
        return None
    if not isinstance(offered, (list, tuple)) or not offered:
        return None
    route = list(offered)
    if route[0] != origin or route[-1] != target:
        return None
    for step in range(len(route) - 1):
        if not _adjacent(forest, route[step], route[step + 1]):
            return None
    return route


def _adjacent(forest, here, there):
    parent = forest["parent"]
    return parent.get(here) == there or parent.get(there) == here


def descends(forest, here, there):
    """True when the step from here to there moves down the hierarchy."""
    return forest["parent"].get(there) == here


def subtree_holds(forest, node, uid):
    """True when uid sits in node's subtree, the node itself included.

    This is the ancestor chain read the other way round, which is why the walk
    computes it from the chain it already has rather than asking graphs again.
    """
    return node in ancestor_chain(forest, uid)


# ---------------------------------------------------------------------------
# Closing field decoding
# ---------------------------------------------------------------------------


def flag_state(context, uid, field_id):
    """Decode the closing field of one node.

    Returns {"closed", "reason", "record", "field"}. `closed` is None when the
    value is missing, multiple or invalid, which blocks a needed departure
    (contract.md:310-311); `reason` is then the text the envelope already
    recorded for that record and field.
    """
    name = declaration_name(context, field_id)
    entry = semantic_field(context, field_id) or {}
    native = (entry.get("native") or {}).get("singleChoice") or {}
    choices = native.get("choices") or FALLBACK_CHOICES
    required = native.get("required", True)
    codec = (entry.get("semantic") or {}).get("codec") or FALLBACK_CODEC

    record = record_of(context, uid) or {}
    fields = record.get("fields") or {}
    present = name in fields
    values = list(fields.get(name) or []) if present else []
    recorded = recorded_problem(context, uid, name)

    if not present:
        return _unusable(uid, name, recorded or _absent_reason(context, uid, name, required))
    if not values:
        return _unusable(
            uid, name, recorded or "Required %s is present with no value." % (name,)
        )
    if len(values) > 1:
        return _unusable(uid, name, recorded or _multiple_reason(name, len(values)))
    if values[0] not in choices:
        return _unusable(
            uid,
            name,
            recorded or "%s value %s is not a declared choice." % (name, values[0]),
        )
    for pair in codec:
        if isinstance(pair, dict) and pair.get("native") == values[0]:
            decoded = pair.get("semantic")
            if isinstance(decoded, bool):
                return {"closed": decoded, "reason": None, "record": uid, "field": name}
    return _unusable(
        uid,
        name,
        recorded or "%s value %s does not decode to a Boolean." % (name, values[0]),
    )


def _unusable(uid, name, reason):
    return {"closed": None, "reason": reason, "record": uid, "field": name}


def _absent_reason(context, uid, name, required):
    model = model_of(context)
    age = "new" if uid in set(model.get("created") or []) else "old"
    if required:
        return "Required %s is absent on %s record %s." % (name, age, uid)
    return "%s is absent on %s record %s." % (name, age, uid)


def _multiple_reason(name, count):
    if count == 2:
        return "Scalar %s carries two values." % (name,)
    return "Scalar %s carries multiple values." % (name,)


# ---------------------------------------------------------------------------
# Endpoints and the walk
# ---------------------------------------------------------------------------


def endpoints_usable(
    context, policy_config, origin, target, origin_label=None, target_label=None
):
    """Check that both endpoints resolve to hierarchy vertices.

    Returns None when both are usable, otherwise {"code", "reason"}: code
    unresolved-target for a dangling uid and code input for a resolved
    non-vertex (contract.md:301-302, contract.md:814). The optional labels name
    the endpoint selectors, which endpoint-path passes as upper and lower.
    """
    forest = hierarchy(context, policy_config)
    return _first_refusal(context, forest, origin, target, origin_label, target_label)


def _first_refusal(context, forest, origin, target, origin_label, target_label):
    for uid, label, role in (
        (origin, origin_label, "origin"),
        (target, target_label, "target"),
    ):
        refusal = _endpoint_refusal(context, forest, uid, label, role)
        if refusal is not None:
            return refusal
    return None


def _endpoint_refusal(context, forest, uid, label, role):
    record = record_of(context, uid)
    if record is None:
        if label:
            reason = (
                "The %s endpoint target does not resolve to a candidate record."
                % (label,)
            )
        elif role == "origin":
            reason = UNRESOLVED_OWNER_REASON
        else:
            reason = UNRESOLVED_TARGET_REASON
        return {"code": "unresolved-target", "reason": reason}
    if uid in forest["vertices"]:
        return None
    element = record.get("element")
    if label:
        reason = (
            "The resolved %s endpoint %s is a %s record and is not a vertex of view %s."
            % (label, uid, element, forest["id"])
        )
    else:
        reason = (
            "The resolved %s %s is a %s record and is not a vertex of view %s."
            % (role, uid, element, forest["id"])
        )
    return {"code": "input", "reason": reason}


def walk(
    context,
    policy_config,
    origin,
    target,
    kind="visible-target",
    require_descent=False,
    origin_label=None,
    target_label=None,
):
    """Run the whole policy decision for one origin and target pair.

    Returns {"status", "code", "path", "walkedPath", "boundary", "reason",
    "record", "field"}. `path` is the full structural route and `walkedPath`
    the permitted prefix including the stopping node (contract.md:646-647);
    both are empty arrays when the endpoints or the hierarchy are unusable, or
    when there is no permitted structural route. `reason`, `record` and
    `field` are set only for a blocked outcome, and `record` and `field` only
    when an unusable closing value is what blocked it.
    """
    forest = hierarchy(context, policy_config)
    refusal = _first_refusal(
        context, forest, origin, target, origin_label, target_label
    )
    if refusal is not None:
        return _outcome("blocked", refusal["code"], reason=refusal["reason"])

    route = structural_route(forest, origin, target)
    if route is None:
        return _outcome("violated", "no-shared-root")
    if require_descent and origin not in ancestor_chain(forest, target):
        return _outcome("violated", kind)

    field_id = (policy_config.get("policy") or {}).get("closedWhenTrue")
    for step in range(len(route) - 1):
        here = route[step]
        if not descends(forest, here, route[step + 1]):
            continue
        state = flag_state(context, here, field_id)
        if state["closed"] is None:
            return _outcome(
                "blocked",
                "input",
                path=route,
                walked=route[: step + 1],
                boundary=here,
                reason=state["reason"],
                record=state["record"],
                field=state["field"],
            )
        if state["closed"] and not subtree_holds(forest, here, origin):
            return _outcome(
                "violated",
                "closed-boundary",
                path=route,
                walked=route[: step + 1],
                boundary=here,
            )
    return _outcome("satisfied", kind, path=route, walked=route)


def _outcome(
    status,
    code,
    path=None,
    walked=None,
    boundary=None,
    reason=None,
    record=None,
    field=None,
):
    return {
        "status": status,
        "code": code,
        "path": list(path or []),
        "walkedPath": list(walked or []),
        "boundary": boundary,
        "reason": reason,
        "record": record,
        "field": field,
    }
