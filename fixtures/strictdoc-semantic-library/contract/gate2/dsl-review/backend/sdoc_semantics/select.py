"""Selector enumeration and the ``where`` filter.

A selector has exactly one of ``records``, ``occurrences`` or ``model``, plus
an optional ``where`` (contract.md:141-147). Enumeration keeps candidate
order, because that order is the primary finding sort key
(contract.md:580-581), and keeps duplicate occurrences, because count and
forest rules are defined over multiplicity (contract.md:143-144).
"""

from .loading import ConfigurationError

SELECTOR_KINDS = ("records", "occurrences", "model")


def subjects(model, select, declarations):
    """Enumerate the subjects a selector yields, before ``where`` is applied.

    A subject is ``{"uid", "record", "occurrence", "occurrenceIndex"}``. A
    record subject carries a null occurrence and occurrenceIndex; the model
    subject carries null for all four (contract.md:610-614).
    """
    if not isinstance(select, dict):
        raise ConfigurationError("A rule selector must be an object.")
    present = [kind for kind in SELECTOR_KINDS if kind in select]
    unknown = set(select) - set(SELECTOR_KINDS) - {"where"}
    if unknown:
        raise ConfigurationError(
            "A rule selector carries the unknown key %s." % sorted(unknown)[0]
        )
    if len(present) != 1:
        raise ConfigurationError(
            "A rule selector needs exactly one of records, occurrences or model."
        )
    kind = present[0]
    if kind == "model":
        if select["model"] is not True:
            raise ConfigurationError("select.model accepts only true.")
        return [_subject(None, None, None, None)]
    configuration = select[kind]
    if not isinstance(configuration, dict):
        raise ConfigurationError("The %s selector must be an object." % kind)
    element = configuration.get("element")
    if not isinstance(element, str) or not element:
        raise ConfigurationError("The %s selector needs an element name." % kind)
    if kind == "records":
        if set(configuration) != {"element"}:
            raise ConfigurationError("A records selector takes only element.")
        return [
            _subject(record["uid"], record, None, None)
            for record in _records(model)
            if record.get("element") == element
        ]
    if set(configuration) != {"element", "role", "direction"}:
        raise ConfigurationError(
            "An occurrences selector takes exactly element, role and direction."
        )
    role = configuration.get("role")
    direction = configuration.get("direction")
    if direction not in ("parent", "child"):
        raise ConfigurationError(
            "An occurrences selector direction must be parent or child."
        )
    selected = []
    for record in _records(model):
        if record.get("element") != element:
            continue
        for index, occurrence in enumerate(record.get("relations") or []):
            if occurrence.get("role") == role and occurrence.get("direction") == direction:
                selected.append(_subject(record["uid"], record, occurrence, index))
    return selected


def apply_filter(context, rule, pre_where_subjects):
    """Evaluate ``where`` over the pre-filter subjects.

    Returns one outcome per subject: ``{"subject", "status", "findings",
    "included", "blocking"}``. A true filter includes the subject, a false one
    excludes it while keeping its filter findings, and a blocked filter leaves
    the subject blocked rather than silently dropping it
    (contract.md:219-224). ``blocking`` carries the resolutions the filter's
    own leaves needed, because the filter is walked for prerequisites too
    (contract.md:743) and its blocked leaves earn causes like any other.
    """
    where = (rule.get("select") or {}).get("where")
    if where is None:
        return [
            {
                "subject": subject,
                "status": "satisfied",
                "findings": [],
                "included": True,
                "blocking": [],
            }
            for subject in pre_where_subjects
        ]
    from . import engine

    outcomes = []
    for subject in pre_where_subjects:
        evaluated = engine.evaluate_check(context, rule, where, subject, "/select/where")
        outcomes.append(
            {
                "subject": subject,
                "status": evaluated["status"],
                "findings": evaluated["findings"],
                "included": evaluated["status"] == "satisfied",
                "blocking": list(evaluated.get("blocking") or []),
            }
        )
    return outcomes


def _subject(uid, record, occurrence, occurrence_index):
    return {
        "uid": uid,
        "record": record,
        "occurrence": occurrence,
        "occurrenceIndex": occurrence_index,
    }


def _records(model):
    if isinstance(model, dict):
        records = model.get("records")
        if isinstance(records, list):
            return records
    return []
