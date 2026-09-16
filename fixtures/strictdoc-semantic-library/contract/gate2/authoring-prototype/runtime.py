"""Bounded contract demonstrator. No Scribe, acquisition, publication, or caches."""


import math


class InputError(ValueError):
    pass


def decode_boolean(values, definition):
    mapping = definition["semantic"]["decode"]
    if not isinstance(values, list) or len(values) != 1:
        raise InputError("Boolean requires exactly one present native value")
    value = values[0]
    if not isinstance(value, str) or value not in mapping:
        raise InputError("unrecognized native Boolean")
    return mapping[value]


def encode_boolean(value, definition):
    if type(value) is not bool:
        raise InputError("semantic Boolean must be a Boolean")
    return definition["semantic"]["encode"]["true" if value else "false"]


def result(rule, evaluation_id, producer, status="satisfied", observations=(), causes=()):
    return {
        "id": rule["id"],
        "evaluationId": evaluation_id,
        "status": status,
        "findings": [
            {
                "producer": producer,
                "code": code,
                "rule": rule["id"],
                "subjects": subjects,
                "locations": locations,
                "message": message,
                "evidence": evidence,
            }
            for code, subjects, locations, message, evidence in observations
        ],
        "causes": list(causes),
    }


def require(condition, message):
    if not condition:
        raise InputError(message)


def identifier(value):
    return isinstance(value, str) and bool(value)


def node_key(ref):
    require(isinstance(ref, dict) and set(ref) == {"model", "uid"}, "invalid NodeRef shape")
    require(all(identifier(ref[key]) for key in ("model", "uid")), "invalid NodeRef identity")
    return ref["model"], ref["uid"]


def candidate_index(candidate):
    """Bounded identity/type prerequisite, not a complete native model validator."""
    require(isinstance(candidate, dict), "invalid candidate shape")
    require(identifier(candidate.get("model")), "missing candidate model identity")
    require(isinstance(candidate.get("nodes"), list), "invalid candidate node list")
    require(isinstance(candidate.get("authoredRelations"), list), "invalid relation list")
    index = {}
    for item in candidate["nodes"]:
        require(isinstance(item, dict), "invalid candidate node")
        key = node_key(item.get("ref"))
        require(key[0] == candidate["model"], "node outside candidate model")
        require(key not in index, "duplicate NodeRef")
        element = item.get("element")
        require(isinstance(element, dict) and set(element) == {"grammar", "element"}
                and all(identifier(v) for v in element.values()), "invalid element identity")
        index[key] = item
    return index


def resolved_relations(candidate, nodes):
    """Resolve in authored order so a later input error retains prior findings."""
    ids = set()
    for relation in candidate["authoredRelations"]:
        require(isinstance(relation, dict), "invalid relation occurrence")
        occurrence_id = relation.get("id")
        require(identifier(occurrence_id), "invalid relation occurrence identity")
        require(occurrence_id not in ids, "duplicate relation occurrence identity")
        ids.add(occurrence_id)
        owner = nodes.get(node_key(relation.get("owner")))
        require(owner is not None, "missing relation owner")
        target = nodes.get(node_key(relation.get("target")))
        require(target is not None, "unresolved selected target")
        require(relation.get("nativeType") in {"Parent", "Child"}, "unsupported native relation kind")
        require(relation.get("role") is None or isinstance(relation.get("role"), str), "invalid native role")
        require(isinstance(relation.get("location"), dict), "missing relation location")
        yield relation, owner, target


def selected(relation, selector, nodes):
    owner = nodes.get(node_key(relation["owner"]))
    require(owner is not None, "missing relation owner")
    return (
        owner["element"]
        == {"grammar": selector["grammar"], "element": selector["ownerElement"]}
        and relation["nativeType"] == selector["nativeType"]
        and relation["role"] == selector["role"]
    )


def target_finding(rule, relation, actual):
    return (
        "target-type",
        [relation["owner"], relation["target"]],
        [relation["location"]],
        "Resolved target has a disallowed element type",
        {
            "selector": rule["config"]["select"],
            "owner": relation["owner"],
            "target": relation["target"],
            "expected": rule["config"]["allowed"],
            "actual": actual,
        },
    )


def shipped_style_targets(rule, candidate, evaluation_id="probe"):
    """A local stand-in for a shipped entry; not the shipped implementation."""
    observations = []
    try:
        nodes = candidate_index(candidate)
        for relation, _owner, target in resolved_relations(candidate, nodes):
            if selected(relation, rule["config"]["select"], nodes):
                if target["element"] not in rule["config"]["allowed"]:
                    observations.append(target_finding(rule, relation, target["element"]))
    except InputError as error:
        return result(rule, evaluation_id, "prototype/shipped-style", "error", observations, [str(error)])
    return result(rule, evaluation_id, "prototype/shipped-style", "violated" if observations else "satisfied", observations)


def independent_targets(rule, candidate, evaluation_id="probe"):
    """Independent selection; same explicit identity/resolution prerequisite."""
    observations = []
    try:
        nodes = candidate_index(candidate)
        selector = rule["config"]["select"]
        owners = {
            node_key(n["ref"])
            for n in candidate["nodes"]
            if n["element"]["grammar"] == selector["grammar"]
            and n["element"]["element"] == selector["ownerElement"]
        }
        for relation, _owner, target in resolved_relations(candidate, nodes):
            if node_key(relation["owner"]) not in owners:
                continue
            if (relation["nativeType"], relation["role"]) != (selector["nativeType"], selector["role"]):
                continue
            if all(target["element"] != allowed for allowed in rule["config"]["allowed"]):
                observations.append(target_finding(rule, relation, target["element"]))
    except InputError as error:
        return result(rule, evaluation_id, "prototype/independent", "error", observations, [str(error)])
    return result(rule, evaluation_id, "prototype/independent", "violated" if observations else "satisfied", observations)


def count(rule, candidate, evaluation_id="probe"):
    observations = []
    try:
        nodes = candidate_index(candidate)
        relations = [r for r, _owner, _target in resolved_relations(candidate, nodes)]
        for owner in candidate["nodes"]:
            if owner["element"] != rule["config"]["records"]:
                continue
            occurrences = [
                r for r in relations
                if node_key(r["owner"]) == node_key(owner["ref"]) and selected(r, rule["config"]["select"], nodes)
            ]
            observed = len(occurrences)
            if not rule["config"]["min"] <= observed <= rule["config"]["max"]:
                observations.append(("cardinality", [owner["ref"]], owner["locations"], "Owned relation cardinality is invalid", {
                    "selector": rule["config"]["select"], "observed": observed,
                    "min": rule["config"]["min"], "max": rule["config"]["max"],
                    "declarations": [r["id"] for r in occurrences],
                }))
    except InputError as error:
        return result(rule, evaluation_id, "prototype/count", "error", observations, [str(error)])
    return result(rule, evaluation_id, "prototype/count", "violated" if observations else "satisfied", observations)


def path_decision(origin, target, parents, closed, downward):
    """Assumes a previously validated finite forest; keeps the original origin."""
    def ancestors(uid):
        output = [uid]
        while uid in parents:
            uid = parents[uid]
            if uid in output:
                raise InputError("forest cycle")
            output.append(uid)
        return output

    left, right = ancestors(origin), ancestors(target)
    if left[-1] != right[-1]:
        return {"code": "different-roots", "origin": origin, "target": target, "roots": [left[-1], right[-1]]}
    common = next(uid for uid in left if uid in right)
    path = left[:left.index(common)] + list(reversed(right[:right.index(common) + 1]))
    if downward and common != origin:
        return {"code": "not-downward", "origin": origin, "target": target, "path": path}
    for current, next_node in zip(path, path[1:]):
        descending = parents.get(next_node) == current
        if descending and closed[current] and current not in left:
            return {"code": "blocked-boundary", "origin": origin, "target": target, "path": path, "boundary": current}
    return None


def endpoint_path(rule, candidate, prior_results, parents, closed, evaluation_id="probe"):
    causes = [dependency for dependency in rule["after"] if prior_results.get(dependency, {}).get("status") != "satisfied"]
    if causes:
        return result(rule, evaluation_id, "prototype/endpoint-path", "blocked", causes=causes)
    observations = []
    try:
        nodes = candidate_index(candidate)
        relations = [r for r, _owner, _target in resolved_relations(candidate, nodes)]
        for owner in candidate["nodes"]:
            if owner["element"] != rule["config"]["records"]:
                continue
            def endpoint(selector):
                values = [r for r in relations if node_key(r["owner"]) == node_key(owner["ref"]) and selected(r, selector, nodes)]
                require(len(values) == 1, "count prerequisite disagrees with candidate")
                # Full NodeRef resolution precedes UID projection into this one-model forest fixture.
                ref = values[0]["target"]
                require(node_key(ref) in nodes and ref["uid"] in closed, "endpoint outside supplied forest")
                return ref["uid"]
            upper, lower = endpoint(rule["config"]["upper"]), endpoint(rule["config"]["lower"])
            failure = path_decision(upper, lower, parents, closed, True)
            if failure:
                observations.append((failure["code"], [owner["ref"]], owner["locations"], "Endpoint path is not permitted", failure))
    except InputError as error:
        return result(rule, evaluation_id, "prototype/endpoint-path", "error", observations, [str(error)])
    return result(rule, evaluation_id, "prototype/endpoint-path", "violated" if observations else "satisfied", observations)


def json_value(value):
    if value is None or isinstance(value, (str, bool, int)):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, list):
        return all(json_value(v) for v in value)
    if isinstance(value, dict):
        return all(isinstance(k, str) and json_value(v) for k, v in value.items())
    return False


def validate_finding(finding, rule_id):
    required = {"producer", "code", "rule", "subjects", "locations", "message", "evidence"}
    require(isinstance(finding, dict) and set(finding) == required, "invalid Finding shape")
    require(all(identifier(finding[k]) for k in ("producer", "code", "rule", "message")), "invalid Finding text/identity")
    require(finding["rule"] == rule_id, "Finding names a different rule")
    require(isinstance(finding["subjects"], list), "invalid Finding subject list")
    for subject in finding["subjects"]:
        # These bounded target/count/path entries advertise NodeRef subjects only.
        node_key(subject)
    require(isinstance(finding["locations"], list), "invalid Finding location list")
    for location in finding["locations"]:
        require(isinstance(location, dict) and set(location) == {"document", "path", "start", "end"}, "invalid Location shape")
        require(identifier(location["document"]) and identifier(location["path"]), "invalid Location identity")
        require(type(location["start"]) is int and type(location["end"]) is int
                and 0 <= location["start"] <= location["end"], "invalid Location coordinates")
    require(isinstance(finding["evidence"], dict) and json_value(finding["evidence"]), "invalid Finding evidence object")


def validate_results(invoked, results, evaluation_id="probe"):
    """Validate the bounded RuleResult/NodeRef-Finding schema before aggregation."""
    require(identifier(evaluation_id), "invalid expected evaluation identity")
    require(isinstance(invoked, list) and isinstance(results, list), "invalid invocation/result list")
    require(all(isinstance(rule, dict) and identifier(rule.get("id")) for rule in invoked), "invalid invocation identity")
    expected = [rule["id"] for rule in invoked]
    require(len(expected) == len(set(expected)), "duplicate invocation identity")
    required = {"id", "evaluationId", "status", "findings", "causes"}
    actual = []
    for item in results:
        require(isinstance(item, dict) and set(item) == required, "invalid result schema")
        require(identifier(item["id"]) and identifier(item["evaluationId"]), "invalid result identity")
        require(item["evaluationId"] == evaluation_id, "result from wrong evaluation")
        require(isinstance(item["status"], str) and item["status"] in {"satisfied", "violated", "blocked", "error"}, "invalid result status")
        require(isinstance(item["findings"], list) and isinstance(item["causes"], list), "invalid findings/causes lists")
        require(all(identifier(cause) for cause in item["causes"]), "invalid cause identity")
        for finding in item["findings"]:
            validate_finding(finding, item["id"])
        if item["status"] == "violated":
            require(bool(item["findings"]), "violation requires a witness")
        if item["status"] in {"blocked", "error"}:
            require(bool(item["causes"] or item["findings"]), "blocked/error result requires diagnostic evidence")
        if item["status"] == "blocked":
            require(bool(item["causes"]), "blocked result requires a cause")
        if item["status"] == "satisfied":
            require(not item["findings"] and not item["causes"], "satisfied result carries failure evidence")
        actual.append(item["id"])
    require(len(actual) == len(set(actual)) and set(actual) == set(expected), "missing, duplicate, or unknown result IDs")
    return "error" if any(r["status"] == "error" for r in results) else "invalid" if any(r["status"] != "satisfied" for r in results) else "valid"
