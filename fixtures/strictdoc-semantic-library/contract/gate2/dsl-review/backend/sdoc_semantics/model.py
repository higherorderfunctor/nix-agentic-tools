"""The in-memory record model and every envelope-level preparation finding.

``build_model`` returns ONE dict carrying the record model, the preparation
findings and the lookup tables the engine and the leaves consult:

    name            the candidate model name
    records         the records in candidate order, defaults already applied
    by_uid          uid to record
    position        uid to its zero-based candidate index
    created         the created uid set as supplied by the caller
    findings        the envelope preparation findings, in emission order
    invalid_fields  (uid, field name) to the finding that made it unusable
    field_errors    the same table, under the name the evaluation context reads
    dangling        (uid, occurrenceIndex) to its unresolved-target finding
    unresolved      the (uid, occurrenceIndex) keys of that table, as a set
    model           the record model on its own, without these extra tables
    bundle          the bundle document
    declarations    the declarations index

The record model is therefore reachable two ways, either as the returned value
or as its ``model`` member, and both are the same records in the same order.

Structural failure that prevents indexing raises
``loading.CandidateShapeError`` instead, which the engine turns into the
cause ``candidate`` path of contract.md:657-658.
"""

from . import findings as findings_module
from .loading import (
    CandidateShapeError,
    ConfigurationError,
    element_named,
    encode_literal,
    native_fields,
    relation_of,
    semantic_fields,
)

# A record has exactly these members, in this order (contract.md:433-434).
MODEL_KEYS = ("uid", "element", "fields", "relations")

# An occurrence has exactly these members (contract.md:439-441).
OCCURRENCE_KEYS = ("role", "direction", "target")

# The identity field name; UID supplies the same string as the record's uid
# (contract.md:342-343, contract.md:439).
IDENTITY_FIELD = "UID"

# The one reason text an unresolved occurrence target carries, measured at
# backend/fixtures/deleted-target-leaves-dangling-reference/results.json. The
# whole evidence object is normative (contract.md:575-577), so the reason is a
# compared string rather than free text.
UNRESOLVED_REASON = "The occurrence target does not resolve to a candidate record."

# Number words for the small multiplicity counts the reason texts spell out.
COUNT_WORDS = {
    2: "two",
    3: "three",
    4: "four",
    5: "five",
    6: "six",
    7: "seven",
    8: "eight",
    9: "nine",
    10: "ten",
}


def count_word(total):
    return COUNT_WORDS.get(total, str(total))


def build_model(candidate, bundle, declarations):
    """Turn candidate.json into the record model and its preparation findings."""
    if not isinstance(candidate, dict):
        raise CandidateShapeError("the candidate is not a JSON object")
    for member in ("model", "records", "created"):
        if member not in candidate:
            raise CandidateShapeError("the candidate is missing " + member)
    extra = sorted(set(candidate) - {"model", "records", "created"})
    if extra:
        raise CandidateShapeError(
            "the candidate carries unsupported " + ", ".join(extra)
        )
    name = candidate["model"]
    if name != declarations["model_name"]:
        raise CandidateShapeError(
            "the candidate model " + repr(name) + " does not match the bundle model "
            + repr(declarations["model_name"])
        )
    records = candidate["records"]
    if not isinstance(records, list):
        raise CandidateShapeError("candidate records must be a JSON array")
    created = read_created(candidate["created"])

    model = {
        "name": name,
        "records": [],
        "by_uid": {},
        "position": {},
        "created": created,
        "findings": [],
        "invalid_fields": {},
        "dangling": {},
        "bundle": bundle,
        "declarations": declarations,
    }
    for record in records:
        checked = check_record_shape(record, declarations)
        uid = checked["uid"]
        if uid in model["by_uid"]:
            raise CandidateShapeError(
                "the candidate uid " + uid + " is not unique", uid=uid
            )
        model["position"][uid] = len(model["records"])
        model["by_uid"][uid] = checked
        model["records"].append(checked)

    apply_creation_defaults(model, declarations)
    validate_native_fields(model, declarations)
    record_unresolved_targets(model)
    return with_lookup_tables(model)


def with_lookup_tables(model):
    """Publish the record model together with its preparation lookup tables."""
    published = dict(model)
    published["model"] = model
    published["field_errors"] = model["invalid_fields"]
    published["unresolved"] = set(model["dangling"])
    return published


def read_created(created):
    """Read the duplicate-free created uid list (contract.md:445-447)."""
    if not isinstance(created, list):
        raise CandidateShapeError("candidate created must be a JSON array")
    seen = set()
    for uid in created:
        if not isinstance(uid, str) or not uid:
            raise CandidateShapeError("a created uid must be a nonempty string")
        if uid in seen:
            raise CandidateShapeError("the created uid " + uid + " is repeated")
        seen.add(uid)
    return seen


def check_record_shape(record, declarations):
    """Enforce the record shape of contract.md:433-450."""
    if not isinstance(record, dict):
        raise CandidateShapeError("a candidate record is not a JSON object")
    missing = sorted(set(MODEL_KEYS) - set(record))
    extra = sorted(set(record) - set(MODEL_KEYS))
    if missing or extra:
        raise CandidateShapeError(
            "a candidate record must have exactly uid, element, fields and relations"
        )
    uid = record["uid"]
    if not isinstance(uid, str) or not uid:
        raise CandidateShapeError("a candidate uid must be a nonempty string")
    element_name = record["element"]
    element = element_named(declarations, element_name) if isinstance(
        element_name, str
    ) else None
    if element is None:
        raise CandidateShapeError(
            "the record " + uid + " names the undeclared element "
            + repr(element_name),
            uid=uid,
        )
    fields = record["fields"]
    if not isinstance(fields, dict):
        raise CandidateShapeError("the fields of " + uid + " must be an object", uid=uid)
    declared = native_fields(declarations, element_name)
    for field_name, values in fields.items():
        if field_name not in declared:
            raise CandidateShapeError(
                "the record " + uid + " carries the undeclared field " + field_name,
                uid=uid,
            )
        if not isinstance(values, list) or any(
            not isinstance(item, str) for item in values
        ):
            raise CandidateShapeError(
                "the field " + field_name + " of " + uid
                + " must be a list of native strings",
                uid=uid,
            )
    if fields.get(IDENTITY_FIELD) != [uid]:
        raise CandidateShapeError(
            "the UID field of " + uid + " must be the one-item list holding its uid",
            uid=uid,
        )
    relations = record["relations"]
    if not isinstance(relations, list):
        raise CandidateShapeError(
            "the relations of " + uid + " must be a JSON array", uid=uid
        )
    for index, occurrence in enumerate(relations):
        check_occurrence_shape(occurrence, uid, index, element["id"], declarations)
    return record


def check_occurrence_shape(occurrence, uid, index, element_id, declarations):
    """An occurrence has exactly role, direction and target, all declared."""
    if not isinstance(occurrence, dict) or set(occurrence) != set(OCCURRENCE_KEYS):
        raise CandidateShapeError(
            "an occurrence of " + uid + " must have exactly role, direction and target",
            uid=uid,
            occurrence_index=index,
        )
    for member in ("role", "target"):
        if not isinstance(occurrence[member], str) or not occurrence[member]:
            raise CandidateShapeError(
                "the " + member + " of an occurrence of " + uid
                + " must be a nonempty string",
                uid=uid,
                occurrence=occurrence,
                occurrence_index=index,
            )
    if relation_of(
        declarations, element_id, occurrence["direction"], occurrence["role"]
    ) is None:
        raise CandidateShapeError(
            "the occurrence " + occurrence["direction"] + " " + occurrence["role"]
            + " of " + uid + " does not resolve to a declared relation",
            uid=uid,
            occurrence=occurrence,
            occurrence_index=index,
        )


def apply_creation_defaults(model, declarations):
    """Fill absent defaulted fields on surviving created records.

    Applied exactly once, after the supplied final state and before any
    validation, only to uids that are both in created and in the final records
    list, only to absent field keys, never overwriting a present list, and
    never to an old record or a baseline record (contract.md:882-896). The
    typed literal encodes through the field codec (contract.md:972-974).
    """
    for uid in model["created"]:
        record = model["by_uid"].get(uid)
        if record is None:
            continue
        for field in semantic_fields(declarations, record["element"]):
            if field["default"] is None:
                continue
            declaration = declarations["field_by_id"][field["field"]]
            field_name = declaration["name"]
            if field_name in record["fields"]:
                continue
            record["fields"][field_name] = [
                encode_literal(field, field["default"]["literal"])
            ]


def validate_native_fields(model, declarations):
    """Validate every record against the authoritative grammar.

    A required absent field, a present list with no value or with more than one
    value, and a singleChoice value outside choices each become one envelope
    finding with status error and code input (contract.md:957-964,
    contract.md:655-656). The evidence shape is the one measured at
    backend/fixtures/invalid-value-multiplicity-errors-never-defaulted and
    backend/fixtures/no-backfill-on-existing-absent-field.
    """
    for record in model["records"]:
        bodies = native_fields(declarations, record["element"])
        for field_name, body in bodies.items():
            if field_name == IDENTITY_FIELD:
                # Any UID problem is a shape failure, checked during indexing.
                continue
            reason = field_problem(
                body, field_name, record, record["uid"] in model["created"]
            )
            if reason is None:
                continue
            present = field_name in record["fields"]
            values = list(record["fields"].get(field_name, []))
            entry = findings_module.finding(
                uid=record["uid"],
                occurrence=None,
                occurrence_index=None,
                predicate_path=None,
                kind=None,
                status="error",
                code="input",
                message=reason,
                evidence={
                    "field": field_name,
                    "input": None,
                    "present": present,
                    "reason": reason,
                    "requires": [],
                    "values": values,
                },
            )
            model["findings"].append(entry)
            model["invalid_fields"][(record["uid"], field_name)] = entry


def field_problem(body, field_name, record, is_new):
    """The reason text for one unusable native field value, or None."""
    type_key = next(iter(body))
    inner = body[type_key]
    if field_name not in record["fields"]:
        if inner.get("required"):
            newness = "new" if is_new else "old"
            return (
                "Required " + field_name + " is absent on " + newness + " record "
                + record["uid"] + "."
            )
        return None
    values = record["fields"][field_name]
    if len(values) == 0:
        if inner.get("required"):
            return "Required " + field_name + " is present with no value."
        return field_name + " is present with no value."
    if len(values) > 1:
        return (
            "Scalar " + field_name + " carries " + count_word(len(values))
            + " values."
        )
    if type_key == "singleChoice" and values[0] not in inner.get("choices", []):
        return field_name + " value " + values[0] + " is not a declared choice."
    return None


def record_unresolved_targets(model):
    """Emit one envelope finding per dangling occurrence.

    Each unresolved target uid yields one top-level input finding with status
    error and code unresolved-target; every rule whose evaluation needs that
    resolution is blocked with the finding's envelope pointer as its cause, and
    the dangling occurrence is retained for diagnostics
    (contract.md:452-465).
    """
    for record in model["records"]:
        for index, occurrence in enumerate(record["relations"]):
            if occurrence["target"] in model["by_uid"]:
                continue
            message = occurrence["target"] + " is not a candidate record."
            entry = findings_module.finding(
                uid=record["uid"],
                occurrence=occurrence,
                occurrence_index=index,
                predicate_path=None,
                kind=None,
                status="error",
                code="unresolved-target",
                message=message,
                evidence={
                    "input": None,
                    "reason": UNRESOLVED_REASON,
                    "requires": [],
                },
            )
            model["findings"].append(entry)
            model["dangling"][(record["uid"], index)] = entry


def decode_flag(model, uid, field_id):
    """Decode one Boolean field of one record through its codec.

    Returns a dict the visibility walk reads directly:

        usable   whether the value decodes to exactly one semantic value
        value    the decoded semantic value, or None when unusable
        present  whether the field key is present
        values   the native strings as authored
        reason   the reason text when unusable, else None
        field    the field name
        record   the record uid

    A missing, multiple or invalid value at a needed departure blocks that
    occurrence (contract.md:310-311) with code input (contract.md:814), and the
    reason text matches the envelope finding for the same value, which is what
    backend/fixtures/invalid-value-multiplicity-errors-never-defaulted expects.
    """
    declarations = model["declarations"]
    declaration = declarations["field_by_id"].get(field_id)
    if declaration is None:
        raise ConfigurationError("unknown field " + str(field_id))
    field_name = declaration["name"]
    answer = {
        "usable": False,
        "value": None,
        "present": False,
        "values": [],
        "reason": None,
        "field": field_name,
        "record": uid,
    }
    record = model["by_uid"].get(uid)
    if record is None:
        answer["reason"] = UNRESOLVED_REASON
        return answer
    element = element_named(declarations, record["element"])
    if element is None or declaration.get("owner") != element["id"]:
        answer["reason"] = (
            "The " + record["element"] + " record " + uid + " has no "
            + field_name + " field."
        )
        return answer
    bodies = native_fields(declarations, record["element"])
    body = bodies.get(field_name)
    answer["present"] = field_name in record["fields"]
    answer["values"] = list(record["fields"].get(field_name, []))
    reason = field_problem(
        body, field_name, record, uid in model["created"]
    ) if body is not None else None
    if reason is not None:
        answer["reason"] = reason
        return answer
    if not answer["present"]:
        answer["reason"] = (
            "Optional " + field_name + " is absent on record " + uid + "."
        )
        return answer
    for field in semantic_fields(declarations, record["element"]):
        if field["field"] != field_id:
            continue
        semantic = field["semantic"]
        if semantic["type"] != "boolean":
            answer["reason"] = (
                "The " + field_name + " field is not a Boolean field."
            )
            return answer
        for entry in semantic["codec"]:
            if entry["native"] == answer["values"][0]:
                answer["usable"] = True
                answer["value"] = entry["semantic"]
                return answer
        answer["reason"] = (
            field_name + " value " + answer["values"][0]
            + " is not a declared choice."
        )
        return answer
    answer["reason"] = (
        "The " + field_name + " field has no semantic description."
    )
    return answer


def occurrence_positions(model):
    """The record-position map the finding sort key reads.

    Candidate record order is the primary finding sort key
    (contract.md:580-581), so this is uid to its zero-based candidate index —
    the same mapping ``model["position"]`` holds, exposed as the value the
    envelope assembler is handed.
    """
    return model["position"]


def owned_occurrences(model, element_name, direction, role):
    """Every owned occurrence matching element, direction and role.

    Yields ``(record, occurrenceIndex, occurrence)`` in owner-record order and
    then relations-array order, preserving duplicates and carrying the true
    occurrenceIndex, which is always the position in the owner's full relations
    array (contract.md:143-145, contract.md:613-616).
    """
    for record in model["records"]:
        if record["element"] != element_name:
            continue
        for index, occurrence in enumerate(record["relations"]):
            if occurrence["direction"] == direction and occurrence["role"] == role:
                yield record, index, occurrence


def records_of(model, element_name):
    """Every record of the named element in candidate order, isolated ones too."""
    return [
        record for record in model["records"] if record["element"] == element_name
    ]
