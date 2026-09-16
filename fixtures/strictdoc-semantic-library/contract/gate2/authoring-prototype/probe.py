"""Execute bounded contract controls; snapshots below are explicitly synthetic."""

import copy
import json
from pathlib import Path

from runtime import (
    InputError, count, decode_boolean, encode_boolean, endpoint_path,
    independent_targets, path_decision, shipped_style_targets, validate_results,
)

HERE = Path(__file__).parent
artifact = json.loads((HERE / "evaluated.json").read_text())["normalized"]
rules = artifact["bundle"]["rules"]
metadata = artifact["semanticTypes"]["fields"][0]
target_rule = next(r for r in rules if r["id"].endswith("FOO/relation/Parent/R/constraint/targetType"))
count_rules = [r for r in rules if r["contract"] == "sdoc-policy.count/v1"]
path_rule = next(r for r in rules if r["contract"] == "sdoc-policy.endpoint-path/v1")
controls = {}
evidence = {}


def check(name, condition):
    assert condition, name
    controls[name] = True


def rejects(name, callback):
    try:
        callback()
    except InputError:
        controls[name] = True
    else:
        raise AssertionError(name)


def node(uid, element="FOO", flag="false"):
    return {
        "ref": {"model": "reference-model", "uid": uid},
        "element": {"grammar": "reference", "element": element},
        "fields": {"FLAG": [flag]} if element == "FOO" else {},
        "locations": [{"document": "synthetic", "path": "model.sdoc", "start": 1, "end": 1}],
    }


def relation(owner, target, role="R", kind="Parent"):
    return {
        "id": f"{owner}-{kind}-{role}-{target}",
        "owner": {"model": "reference-model", "uid": owner},
        "target": {"model": "reference-model", "uid": target},
        "nativeType": kind, "role": role,
        "location": {"document": "synthetic", "path": "model.sdoc", "start": 1, "end": 1},
    }


parents = {"F1": "F0", "F1a": "F1", "F2": "F0", "F2a": "F2", "F2b": "F2", "G1": "G0"}
base = {
    "model": "reference-model",
    "nodes": [node(uid, flag="true" if uid == "F2" else "false") for uid in ["F0", "F1", "F1a", "F2", "F2a", "F2b", "G0", "G1", "I0"]] + [node("Z0", "BAZ")],
    "authoredRelations": [relation(child, parent, "H") for child, parent in parents.items()],
}
closed = {n["ref"]["uid"]: decode_boolean(n["fields"]["FLAG"], metadata) for n in base["nodes"] if n["element"]["element"] == "FOO"}

for label, added, expected in [
    ("G01", relation("F1a", "F2"), "satisfied"),
    ("G02", relation("F1a", "Z0"), "violated"),
    ("G03", relation("Z0", "I0"), "satisfied"),
    ("sameRoleChildControl", relation("F1a", "Z0", kind="Child"), "satisfied"),
    ("missingTarget", relation("F1a", "MISSING"), "error"),
]:
    candidate = copy.deepcopy(base)
    candidate["authoredRelations"].append(added)
    shipped = shipped_style_targets(target_rule, candidate)
    independent = independent_targets(target_rule, candidate)
    check(label, shipped["status"] == independent["status"] == expected)
    normalized = copy.deepcopy([shipped, independent])
    for report in normalized:
        for finding in report["findings"]:
            finding.pop("producer")
    check(label + "-entryParity", normalized[0] == normalized[1])
    evidence[label] = {"input": {"base": "Base", "appendRelations": [added]}, "shippedStyle": shipped, "independent": independent}

check("relationEmptyCollectionVacuous", shipped_style_targets(target_rule, base)["status"] == "satisfied")
for values in [[], ["true", "false"], ["FALSE"], [""], ["TBD"], ["TBC"], [False], None]:
    rejects("invalidBoolean:" + repr(values), lambda values=values: decode_boolean(values, metadata))
for value in [False, True]:
    check("booleanRoundTrip:" + str(value), decode_boolean([encode_boolean(value, metadata)], metadata) is value)
rejects("stringIsNotSemanticBoolean", lambda: encode_boolean("false", metadata))

for label, origin, target, downward, expected in [
    ("T01", "F1a", "F2", False, None),
    ("T02", "F1a", "F2a", False, "blocked-boundary"),
    ("T06", "F0", "F2", True, None),
    ("T07", "F0", "F2a", True, "blocked-boundary"),
    ("T08", "F0", "G1", True, "different-roots"),
    ("closedOrigin", "F2", "F2a", True, None),
    ("internalSibling", "F2a", "F2b", False, None),
    ("exitClosed", "F2a", "F1a", False, None),
    ("siblingBridge", "F1", "F2", True, "not-downward"),
]:
    decision = path_decision(origin, target, parents, closed, downward)
    check(label, (decision or {}).get("code") == expected)
    evidence[label + "-path"] = decision
check("T03", path_decision("F1a", "F2a", parents, {**closed, "F2": False}, False) is None)
check("T04", path_decision("F1a", "F2a", parents, closed, False)["boundary"] == "F2")
check("nestedOriginalOrigin", path_decision("F2", "F2a1", {**parents, "F2a1": "F2a"}, {**closed, "F2a": True, "F2a1": False}, True)["boundary"] == "F2a")

for label, endpoints, expected_count, expected_path in [
    ("B01", [relation("M", "F0", "P"), relation("M", "F2", "Q", "Child")], ["satisfied", "satisfied"], "satisfied"),
    ("B02", [relation("M", "F0", "P")], ["satisfied", "violated"], "blocked"),
    ("twoQ", [relation("M", "F0", "P"), relation("M", "F2", "Q", "Child"), relation("M", "F1", "Q", "Child")], ["satisfied", "violated"], "blocked"),
    ("bridgeHidden", [relation("M", "F0", "P"), relation("M", "F2a", "Q", "Child")], ["satisfied", "satisfied"], "violated"),
]:
    candidate = copy.deepcopy(base)
    candidate["nodes"].append(node("M", "BAR"))
    candidate["authoredRelations"].extend(endpoints)
    results = [count(r, candidate) for r in count_rules]
    check(label + "-counts", [r["status"] for r in results] == expected_count)
    prior = {r["id"]: r for r in results}
    # Supplied forest prerequisite is a contract fixture, not an executed forest validator.
    prior["reference/view/H/valid"] = {"status": "satisfied"}
    path_result = endpoint_path(path_rule, candidate, prior, parents, closed)
    check(label + "-path", path_result["status"] == expected_path)
    check(label + "-resultContract", validate_results(count_rules + [path_rule], results + [path_result]) == ("valid" if expected_path == "satisfied" else "invalid"))
    evidence[label] = {"input": {"base": "Base", "appendNodes": [node("M", "BAR")], "appendRelations": endpoints}, "results": results + [path_result], "forestPrerequisite": "supplied-valid-contract-fixture"}

valid_result = shipped_style_targets(target_rule, base)
rejects("missingResult", lambda: validate_results([target_rule], []))
rejects("duplicateResult", lambda: validate_results([target_rule], [valid_result, valid_result]))
rejects("unknownResult", lambda: validate_results([target_rule], [{**valid_result, "id": "unknown"}]))
rejects("invalidResultStatus", lambda: validate_results([target_rule], [{**valid_result, "status": "pass"}]))
rejects("emptyFindingsNotSuccess", lambda: validate_results([target_rule], [{**valid_result, "status": "violated"}]))
# Review regressions: validate wire data types before status/aggregation.
for name, changes in [
    ("nullResultLists", {"findings": None, "causes": None}),
    ("numericEvaluationId", {"evaluationId": 7}),
    ("wrongEvaluationId", {"evaluationId": "another-evaluation"}),
    ("numericResultId", {"id": 7}),
    ("unstructuredFinding", {"status": "violated", "findings": ["wrong"]}),
    ("stringCauseList", {"status": "blocked", "causes": "missing"}),
    ("numericCause", {"status": "blocked", "causes": [7]}),
    ("emptyCause", {"status": "blocked", "causes": [""]}),
    ("numericStatus", {"status": 7}),
]:
    rejects(name, lambda changes=changes: validate_results([target_rule], [{**valid_result, **changes}]))
rejects("nonListResults", lambda: validate_results([target_rule], None))
rejects("nonObjectResult", lambda: validate_results([target_rule], ["wrong"]))
rejects("duplicateInvocation", lambda: validate_results([target_rule, target_rule], [valid_result]))
check("explicitEvaluationId", validate_results([target_rule], [shipped_style_targets(target_rule, base, "other-evaluation")], "other-evaluation") == "valid")
wrong_candidate = copy.deepcopy(base)
wrong_candidate["authoredRelations"].append(relation("F1a", "Z0"))
wrong_report = shipped_style_targets(target_rule, wrong_candidate)
check("structuredViolationAccepted", validate_results([target_rule], [wrong_report]) == "invalid")
for name, changes in [
    ("findingMissingKey", None),
    ("findingNumericProducer", {"producer": 1}),
    ("findingWrongRule", {"rule": "other-rule"}),
    ("findingNullSubjects", {"subjects": None}),
    ("findingMalformedSubject", {"subjects": [{"uid": "F1a"}]}),
    ("findingNumericSubject", {"subjects": [{"model": "reference-model", "uid": 1}]}),
    ("findingNullLocations", {"locations": None}),
    ("findingStringLocation", {"locations": ["model.sdoc"]}),
    ("findingNumericPath", {"locations": [{"document": "d", "path": 1, "start": 0, "end": 1}]}),
    ("findingReversedLocation", {"locations": [{"document": "d", "path": "p", "start": 2, "end": 1}]}),
    ("findingBooleanCoordinate", {"locations": [{"document": "d", "path": "p", "start": False, "end": 1}]}),
    ("findingNullEvidence", {"evidence": None}),
    ("findingNonJsonEvidence", {"evidence": {"invalid": {1, 2}}}),
    ("findingInfiniteEvidence", {"evidence": {"invalid": float("inf")}}),
    ("findingNumericMessage", {"message": 7}),
]:
    report = copy.deepcopy(wrong_report)
    if changes is None:
        del report["findings"][0]["code"]
    else:
        report["findings"][0].update(changes)
    rejects(name, lambda report=report: validate_results([target_rule], [report]))

# Both target entries use full NodeRefs and the same explicit input prerequisite.
def target_pair(label, candidate, expected, findings=0):
    reports = [entry(target_rule, candidate) for entry in (shipped_style_targets, independent_targets)]
    check(label, all(r["status"] == expected and len(r["findings"]) == findings for r in reports))
    normalized = copy.deepcopy(reports)
    for report in normalized:
        for finding in report["findings"]:
            finding.pop("producer")
    check(label + "-parity", normalized[0] == normalized[1])
    for report in reports:
        validate_results([target_rule], [report])
    evidence[label] = {"shippedStyle": reports[0], "independent": reports[1]}

for label, owner_change, target_change in [
    ("wrongTargetModel", {}, {"model": "other-model"}),
    ("wrongOwnerModel", {"model": "other-model"}, {}),
    ("missingOwner", {"uid": "absent"}, {}),
    ("numericOwner", {"uid": 1}, {}),
    ("numericTarget", {}, {"uid": 1}),
]:
    candidate = copy.deepcopy(base)
    added = relation("F1a", "F2")
    added["owner"].update(owner_change)
    added["target"].update(target_change)
    candidate["authoredRelations"].append(added)
    target_pair(label, candidate, "error")

for label, modify in [
    ("duplicateNodeRef", lambda c: c["nodes"].append(copy.deepcopy(c["nodes"][0]))),
    ("duplicateUidAcrossGrammar", lambda c: c["nodes"].append({**copy.deepcopy(c["nodes"][0]), "element": {"grammar": "other", "element": "FOO"}})),
    ("nodeOutsideCandidateModel", lambda c: c["nodes"].append({**node("F2"), "ref": {"model": "other-model", "uid": "F2"}})),
    ("duplicateRelationId", lambda c: c["authoredRelations"].append(copy.deepcopy(c["authoredRelations"][0]))),
    ("missingCandidateModel", lambda c: c.pop("model")),
]:
    candidate = copy.deepcopy(base)
    modify(candidate)
    target_pair(label, candidate, "error")

candidate = copy.deepcopy(base)
foreign = node("X", "FOO")
foreign["element"]["grammar"] = "other-grammar"
candidate["nodes"].append(foreign)
candidate["authoredRelations"].append(relation("X", "Z0"))
target_pair("otherGrammarOwnerIsUnselected", candidate, "satisfied")
candidate["authoredRelations"][-1] = relation("F1a", "X")
target_pair("otherGrammarTargetViolates", candidate, "violated", 1)

for label, late in [
    ("retainedFindingThenMissingTarget", relation("F1a", "absent")),
    ("retainedFindingThenMissingOwner", relation("absent", "F2")),
    ("retainedFindingThenDuplicateRelation", relation("F1a", "Z0")),
]:
    candidate = copy.deepcopy(wrong_candidate)
    candidate["authoredRelations"].append(late)
    target_pair(label, candidate, "error", 1)

output = {"count": len(controls), "controls": controls, "evidence": evidence,
          "inputs": {"Base": base, "forest": {"parents": parents, "closed": closed, "validity": "supplied-contract-fixture"}},
          "limits": ["synthetic model inputs", "supplied valid forest", "no native/Scribe enforcement", "no process transport", "no default provider or atomic batch execution"]}
(HERE / "runtime-results.json").write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
print(f"{len(controls)} bounded runtime controls passed")
