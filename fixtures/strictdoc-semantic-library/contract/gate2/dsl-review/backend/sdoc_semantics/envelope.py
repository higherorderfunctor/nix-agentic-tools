"""Envelope assembly and every ordering rule.

Kept apart from scheduling so the normative output shape is auditable in one
short file: the key set of contract.md:535-573, the two orderings of
contract.md:579-583, the envelope status ladder of contract.md:663-665, and
the result protocol invariant of contract.md:570-573.
"""

from . import findings as finding_support
from .loading import ConfigurationError


def pointer_index(envelope_findings):
    """Map an implicated record detail to its envelope JSON Pointer.

    A blocked leaf names the record and field it could not read, or names the
    occurrences whose targets do not resolve. Both have to become the
    ``/findings/N`` pointer the entry lists as its cause
    (contract.md:625-628), so this index carries two key shapes:

    * ``("field", uid, field name)`` for a native field validation finding
    * ``("occurrence", uid, occurrenceIndex)`` for an occurrence finding

    There is deliberately no key for a whole code. An entry may cite only the
    findings its own evaluation needs (contract.md:462-463), so a lookup that
    answered with every finding carrying one code could only over-cite.
    """
    index = {}
    for position, entry in enumerate(envelope_findings):
        pointer = "/findings/%d" % position
        uid = entry.get("uid")
        evidence = entry.get("evidence") or {}
        field = evidence.get("field")
        if uid is not None and isinstance(field, str):
            index.setdefault(("field", uid, field), pointer)
        occurrence_index = entry.get("occurrenceIndex")
        if uid is not None and occurrence_index is not None:
            index.setdefault(("occurrence", uid, occurrence_index), pointer)
    return index


def assemble(evaluation, baseline_identity, envelope_findings, entries, positions, rule_ids=None):
    """Build the envelope, sorting both finding lists and checking the results.

    ``expected`` is false because true marks an illustrative expectation and
    false an actual evaluator response (contract.md:566-567).
    """
    ordered_envelope = sort_findings(envelope_findings, positions)
    ordered_entries = _ordered_entries(entries, rule_ids)
    results = []
    for entry in ordered_entries:
        results.append(
            {
                "rule": entry["rule"],
                "status": entry["status"],
                "findings": sort_findings(entry.get("findings") or [], positions),
                "causes": list(entry.get("causes") or []),
            }
        )
    statuses = [item["status"] for item in ordered_envelope]
    statuses.extend(item["status"] for item in results)
    return {
        "evaluation": evaluation,
        "baseline": baseline_identity,
        "expected": False,
        "status": finding_support.worst(statuses),
        "findings": ordered_envelope,
        "results": results,
    }


def sort_findings(unsorted, positions):
    """Order findings by the normative key of contract.md:580-583."""
    return sorted(unsorted, key=lambda item: finding_support.sort_key(item, positions))


def _ordered_entries(entries, rule_ids):
    listed = list(entries)
    if rule_ids is None:
        return listed
    by_rule = {}
    for entry in listed:
        rule = entry["rule"]
        if rule in by_rule:
            raise ConfigurationError("The results carry rule %s twice." % rule)
        by_rule[rule] = entry
    unknown = set(by_rule) - set(rule_ids)
    if unknown:
        raise ConfigurationError(
            "The results carry the unknown rule %s." % sorted(unknown)[0]
        )
    missing = [rule for rule in rule_ids if rule not in by_rule]
    if missing:
        raise ConfigurationError("The results have no entry for rule %s." % missing[0])
    return [by_rule[rule] for rule in rule_ids]
