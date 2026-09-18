"""The one place a finding is built and the one place statuses are compared.

Every normative output shape that more than one module needs lives here, so the
finding key set (contract.md:609-611), the indexed evidence occurrence
(contract.md:614-618), the blocked evidence merge (contract.md:639), the finding
sort order (contract.md:580-583) and the two worst-of ladders
(contract.md:589-590 and contract.md:663-664) each exist exactly once.
"""

# The nine finding members, in the order contract.md:609-611 lists them. Object
# member order never affects comparison (contract.md:578-579); the order is kept
# only so a written envelope reads like the contract's own samples.
FINDING_KEYS = (
    "uid",
    "occurrence",
    "occurrenceIndex",
    "predicatePath",
    "kind",
    "status",
    "code",
    "message",
    "evidence",
)

# The three members an occurrence repeats in a finding (contract.md:613-614).
OCCURRENCE_KEYS = ("role", "direction", "target")

# The blocked, input, execution and configuration evidence members that a
# diagnostic adds to whatever leaf evidence it carries (contract.md:639).
BLOCKED_KEYS = ("reason", "input", "requires")

# One shared rank map serves both ladders. The rule ladder never sees error,
# because leaves never produce it (contract.md:587-588); the envelope ladder
# does, and error outranks everything (contract.md:663-664).
STATUS_RANK = {"satisfied": 0, "violated": 1, "blocked": 2, "error": 3}

# The complete status space (contract.md:778).
STATUSES = tuple(sorted(STATUS_RANK, key=lambda name: STATUS_RANK[name]))


def finding(
    uid,
    occurrence,
    occurrence_index,
    predicate_path,
    kind,
    status,
    code,
    message,
    evidence,
):
    """Build one finding with exactly the nine normative members."""
    if status not in STATUS_RANK:
        raise ValueError("unsupported finding status " + repr(status))
    return {
        "uid": uid,
        "occurrence": plain_occurrence(occurrence),
        "occurrenceIndex": occurrence_index,
        "predicatePath": predicate_path,
        "kind": kind,
        "status": status,
        "code": code,
        "message": message,
        "evidence": evidence,
    }


def plain_occurrence(occurrence):
    """Repeat exactly role, direction and target, or pass a null through."""
    if occurrence is None:
        return None
    return {key: occurrence[key] for key in OCCURRENCE_KEYS}


def indexed_occurrence(record_uid, index, occurrence, with_owner=False):
    """Build the evidence form of an occurrence.

    An indexed evidence occurrence carries occurrenceIndex, role, direction and
    target; a graph witness edge additionally carries the owner's uid
    (contract.md:616-618). ``record_uid`` is the owner, which is only emitted
    for the witness form.
    """
    indexed = {"occurrenceIndex": index}
    indexed.update(plain_occurrence(occurrence))
    if with_owner:
        indexed["owner"] = record_uid
    return indexed


def blocked_evidence(leaf_evidence, reason, input_id=None, requires=None, extra=None):
    """Merge a leaf's own evidence with the blocked members.

    A blocked leaf retains its leaf evidence shape (contract.md:639), so the
    merge starts from ``leaf_evidence`` and adds reason, input and requires.
    ``extra`` carries the further record, field or occurrence details the same
    row allows, such as the record and field of an unusable needed value.
    """
    merged = dict(leaf_evidence or {})
    merged["reason"] = reason
    merged["input"] = input_id
    merged["requires"] = list(requires or [])
    if extra:
        merged.update(extra)
    return merged


def sort_key(one_finding, positions):
    """The normative finding order of contract.md:580-583.

    Candidate record order first, then ascending occurrenceIndex, then
    ascending predicatePath as lexicographic JSON Pointer text. A null key
    sorts before a non-null one, and a model subject has no record position.
    """
    unplaced = len(positions)
    uid = one_finding.get("uid")
    if uid is None:
        uid_rank, place = 0, 0
    else:
        uid_rank, place = 1, positions.get(uid, unplaced)
    index = one_finding.get("occurrenceIndex")
    if index is None:
        index_rank, index_value = 0, 0
    else:
        index_rank, index_value = 1, index
    pointer = one_finding.get("predicatePath")
    if pointer is None:
        pointer_rank, pointer_text = 0, ""
    else:
        pointer_rank, pointer_text = 1, pointer
    return (
        uid_rank,
        place,
        index_rank,
        index_value,
        pointer_rank,
        pointer_text,
    )


def rule_status(subject_statuses):
    """Aggregate selected subjects into a rule entry status.

    Blocked outranks violated, which outranks satisfied (contract.md:589-590).
    A rule over zero selected subjects is satisfied (contract.md:591-593). A
    rule-level error takes precedence and is applied by the caller, so an error
    here would mean a leaf produced one, which cannot happen
    (contract.md:587-588).
    """
    for status in subject_statuses:
        if status == "error":
            raise ValueError("a selected subject cannot carry status error")
    return worst(subject_statuses)


def worst(statuses):
    """The envelope ladder: error, blocked, violated, satisfied.

    An empty set is satisfied (contract.md:663-665).
    """
    found = "satisfied"
    for status in statuses:
        if STATUS_RANK[status] > STATUS_RANK[found]:
            found = status
    return found
