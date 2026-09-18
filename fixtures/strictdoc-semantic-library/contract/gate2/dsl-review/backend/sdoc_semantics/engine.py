"""Scheduling, expression evaluation and the public entry point.

Rule order of business, fixed by contract.md:756-758 and the blocking rules
around it: a rule's own external input acquisition first, so a rule whose
input failed reports error rather than blocked; then structural candidate
being unusable; then prerequisites, at whole-rule granularity; then selection,
filtering and per-subject expression evaluation.

Rules are evaluated in a dependency order over ``requires``, while result
entries are emitted in bundle rule order, because rule-array order is not a
schedule (contract.md:570-573, contract.md:732).
"""

import os

from . import envelope as envelope_support
from . import findings as finding_support
from . import leaves as leaf_support
from . import loading
from . import model as model_support
from . import providers
from . import select as select_support

OPERATOR_KEYS = ("all", "any", "not")
FAILED_STATUSES = ("violated", "blocked", "error")
PREREQUISITE_REASON = "A required rule did not hold."
FIELD_PROBLEM_NAMES = (
    "invalid_fields",
    "fieldProblems",
    "field_problems",
    "fieldErrors",
    "field_errors",
)
DANGLING_NAMES = ("dangling", "unresolved", "unresolvedTargets", "unresolved_targets")
STRUCTURAL_REASON = "The candidate could not be indexed."


class Context(dict):
    """Everything a leaf may consult, as a mapping with attribute access.

    Leaves receive this object as their first argument. It carries the model,
    the declarations index, the bundle's named configurations, the captured
    snapshots, and every lookup table the model preparation step produced, so
    a leaf never has to reach back into the engine.
    """

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)

    def view(self, view_id):
        return self._named("views", view_id)

    def projection(self, projection_id):
        return self._named("projections", projection_id)

    def input_declaration(self, input_id):
        return self._named("inputs", input_id)

    def snapshot(self, input_id):
        return (self.get("snapshots") or {}).get(input_id)

    def identity(self, input_id):
        return (self.get("identities") or {}).get(input_id)

    def field_error(self, uid, field_name):
        return (self.get("field_errors") or {}).get((uid, field_name))

    def pointer(self, *key):
        return (self.get("pointers") or {}).get(tuple(key))

    def _named(self, collection, wanted_id):
        for declaration in (self.get("bundle") or {}).get(collection) or []:
            if declaration.get("id") == wanted_id:
                return declaration
        return None


def evaluate_bundle(bundle_path, candidate_path, invocation_path=None, evaluation=None):
    """Evaluate one candidate against one bundle and return the envelope."""
    loaded = loading.load_bundle(bundle_path)
    document = _document(loaded, bundle_path)
    section = _section(document)
    declarations = _declarations_index(loaded, document)
    rules = _rules(declarations, section)
    candidate = loading.read_json(candidate_path)
    invocation, invocation_directory = _invocation(invocation_path, candidate_path)

    declared = providers.declared_inputs(document)
    acquisitions = providers.acquire(
        document, invocation, invocation_directory, declarations
    )

    structural = None
    envelope_findings = []
    model_data = None
    prepared = {}
    try:
        prepared = model_support.build_model(
            candidate, _bundle_argument(loaded, document), declarations
        )
    except loading.CandidateShapeError as problem:
        structural = str(problem)
        envelope_findings = [_structural_finding(problem, structural)]
    else:
        model_data, envelope_findings = _unpack(prepared)

    envelope_findings = envelope_findings + _acquisition_findings(
        section, rules, acquisitions
    )
    positions = _positions(model_data)
    envelope_findings = envelope_support.sort_findings(envelope_findings, positions)
    pointers = envelope_support.pointer_index(envelope_findings)

    context = _context(
        document,
        section,
        declarations,
        loaded,
        model_data,
        prepared,
        envelope_findings,
        positions,
        pointers,
        acquisitions,
    )

    order, configuration_problems = _schedule(rules)
    by_id = {rule["id"]: rule for rule in rules}
    entries = {}
    for rule_id in order:
        entries[rule_id] = _evaluate_rule(
            context,
            by_id[rule_id],
            entries,
            acquisitions,
            declared,
            structural,
            configuration_problems.get(rule_id),
        )

    return envelope_support.assemble(
        evaluation if evaluation else _default_evaluation(candidate_path),
        _baseline_identity(section, rules, acquisitions),
        envelope_findings,
        [entries[rule["id"]] for rule in rules],
        positions,
        rule_ids=[rule["id"] for rule in rules],
    )


def evaluate_check(context, rule, check, subject, predicate_path):
    """Evaluate one check expression for one subject.

    Returns ``{"status", "findings", "blocking"}``, where the status is the
    expression's own truth: satisfied for true, violated for false, blocked
    when a child could not be evaluated. Children are evaluated without
    short-circuiting, every evaluated leaf keeps its own finding and status,
    and ``not`` preserves blocked (contract.md:226-233). ``blocking`` unions
    the ``(uid, occurrenceIndex)`` pairs the evaluated leaves needed resolved.
    """
    if not isinstance(check, dict) or not check:
        raise loading.ConfigurationError("A check must be one leaf or one operator.")
    operators = [key for key in OPERATOR_KEYS if key in check]
    if operators:
        if len(check) != 1:
            raise loading.ConfigurationError(
                "A check carrying the operator %s carries extra keys." % operators[0]
            )
        return _evaluate_operator(context, rule, check, operators[0], subject, predicate_path)
    return _evaluate_leaf(context, rule, check, subject, predicate_path)


def _evaluate_operator(context, rule, check, operator, subject, predicate_path):
    if operator == "not":
        child = evaluate_check(
            context, rule, check["not"], subject, predicate_path + "/not"
        )
        if child["status"] == "blocked":
            return child
        negated = "violated" if child["status"] == "satisfied" else "satisfied"
        return {
            "status": negated,
            "findings": child["findings"],
            "blocking": child["blocking"],
        }

    children = check[operator]
    if not isinstance(children, list):
        raise loading.ConfigurationError(
            "The operator %s takes a list of checks." % operator
        )
    collected = []
    statuses = []
    needed = []
    for position, child in enumerate(children):
        evaluated = evaluate_check(
            context,
            rule,
            child,
            subject,
            "%s/%s/%d" % (predicate_path, operator, position),
        )
        collected.extend(evaluated["findings"])
        needed.extend(evaluated["blocking"])
        statuses.append(evaluated["status"])
    if not children:
        status = "satisfied" if operator == "all" else "violated"
        collected.append(
            _subject_finding(
                subject,
                predicate_path,
                None,
                status,
                "expression",
                "The %s operator has no children." % operator,
                {"operator": operator},
            )
        )
        return {"status": status, "findings": collected, "blocking": needed}
    if "blocked" in statuses:
        return {"status": "blocked", "findings": collected, "blocking": needed}
    if operator == "all":
        holds = all(status == "satisfied" for status in statuses)
    else:
        holds = any(status == "satisfied" for status in statuses)
    return {
        "status": "satisfied" if holds else "violated",
        "findings": collected,
        "blocking": needed,
    }


def _evaluate_leaf(context, rule, leaf, subject, predicate_path):
    kind = leaf.get("kind")
    table = getattr(leaf_support, "LEAVES", {})
    if kind not in table:
        raise loading.ConfigurationError("The leaf kind %r is not supported." % (kind,))
    context["rule"] = rule
    context["predicatePath"] = predicate_path
    result = table[kind](context, leaf, subject)
    status = result["status"]
    if status == "error":
        raise loading.ConfigurationError(
            "The %s leaf returned error, which leaves never produce." % kind
        )
    evidence = result.get("evidence")
    finding = _subject_finding(
        subject,
        predicate_path,
        kind,
        status,
        result["code"],
        _leaf_message(kind, status, evidence),
        evidence if isinstance(evidence, dict) else {},
    )
    return {
        "status": status,
        "findings": [finding],
        "blocking": [tuple(pair) for pair in result.get("blocking") or []],
    }


def _evaluate_rule(
    context, rule, entries, acquisitions, declared, structural, configuration_problem
):
    rule_id = rule["id"]
    input_problems = _input_problems(rule, acquisitions, declared)
    if input_problems:
        return _entry(
            rule_id,
            "error",
            [
                _non_leaf_finding(None, "error", code, reason, input_id, [])
                for code, input_id, reason in input_problems
            ],
            _unique([input_id for _, input_id, _ in input_problems]),
        )
    if configuration_problem is not None:
        reason, offending = configuration_problem
        return _entry(
            rule_id,
            "error",
            [_non_leaf_finding(None, "error", "configuration", reason, None, offending)],
            [],
        )
    if structural is not None and "candidate" in (rule.get("inputs") or []):
        return _entry(rule_id, "blocked", [], ["candidate"])

    failed = [
        required
        for required in rule.get("requires") or []
        if (entries.get(required) or {"status": "blocked"})["status"] in FAILED_STATUSES
    ]
    if failed:
        blocked = [
            _non_leaf_finding(subject, "blocked", "prerequisite", PREREQUISITE_REASON, None, failed)
            for subject in select_support.subjects(
                context["model"], rule["select"], context["declarations"]
            )
        ]
        return _entry(rule_id, "blocked", blocked, list(failed))

    pre_where = select_support.subjects(
        context["model"], rule["select"], context["declarations"]
    )
    collected = []
    statuses = []
    needed = []
    for outcome in select_support.apply_filter(context, rule, pre_where):
        collected.extend(outcome["findings"])
        needed.extend(outcome.get("blocking") or [])
        if outcome["status"] == "blocked":
            statuses.append("blocked")
            continue
        if not outcome["included"]:
            continue
        evaluated = evaluate_check(
            context, rule, rule["check"], outcome["subject"], "/check"
        )
        collected.extend(evaluated["findings"])
        needed.extend(evaluated["blocking"])
        statuses.append(evaluated["status"])
    return _entry(
        rule_id,
        finding_support.rule_status(statuses) if statuses else "satisfied",
        collected,
        _causes(context, collected, needed),
    )


def _input_problems(rule, acquisitions, declared):
    problems = []
    for input_id in rule.get("inputs") or []:
        if input_id == "candidate":
            continue
        if input_id not in declared:
            problems.append(
                (
                    "configuration",
                    input_id,
                    "Rule %s declares the external input %s, which the bundle "
                    "does not declare." % (rule["id"], input_id),
                )
            )
            continue
        acquired = acquisitions.get(input_id)
        if acquired is None:
            problems.append(
                (
                    "execution",
                    input_id,
                    "The external input %s was never acquired." % input_id,
                )
            )
        elif not acquired.get("ok"):
            problems.append(("execution", input_id, acquired["failure"]["reason"]))
    return problems


def _causes(context, collected, needed_occurrences):
    """Collect an entry's causes in first-emission order.

    A blocked leaf cites the envelope finding that made its data unusable: the
    native field validation finding for the record and field it could not
    decode, or the unresolved-target finding for the occurrence whose target
    does not resolve (contract.md:625-628). A subject-local block with no
    envelope finding behind it contributes nothing, so an entry can be blocked
    with empty causes.

    Only a resolution the rule's own evaluation needs may be cited
    (contract.md:462-463). A leaf over the whole model carries no indexed
    subject, so it names the occurrences it read in ``needed_occurrences``
    instead; citing every unresolved-target finding in the envelope would
    attribute an unrelated dangling occurrence to a rule that does not read
    it, which is what leaves a dangling R out of the H forest's causes while
    the same R still blocks the native graph.
    """
    pointers = context.get("pointers") or {}
    causes = []
    for finding in collected:
        if finding["status"] != "blocked":
            continue
        evidence = finding.get("evidence") or {}
        code = finding.get("code")
        if code == "input":
            record = evidence.get("record")
            field = evidence.get("field")
            if isinstance(record, str) and isinstance(field, str):
                causes.append(pointers.get(("field", record, field)))
            continue
        if code != "unresolved-target":
            continue
        implicated = _implicated_occurrences(finding, evidence)
        if not implicated:
            implicated = list(needed_occurrences)
        causes.extend(
            pointers.get(("occurrence", uid, index)) for uid, index in implicated
        )
    return _unique([cause for cause in causes if cause is not None])


def _implicated_occurrences(finding, evidence):
    """Name every occurrence a blocked finding could be citing."""
    owner = finding.get("uid")
    if finding.get("occurrenceIndex") is not None and owner is not None:
        return [(owner, finding["occurrenceIndex"])]
    found = []
    for indexed in _indexed_occurrences(evidence):
        holder = indexed.get("owner") or indexed.get("uid") or owner
        if holder is not None:
            found.append((holder, indexed["occurrenceIndex"]))
    return found


def _indexed_occurrences(value):
    if isinstance(value, dict):
        if value.get("occurrenceIndex") is not None and "role" in value:
            yield value
            return
        for nested in value.values():
            yield from _indexed_occurrences(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _indexed_occurrences(nested)


def _schedule(rules):
    """Order rules over ``requires`` and name the configuration failures.

    An unknown prerequisite id and a dependency cycle are configuration errors
    on the referring rule (contract.md:761). Both are reported rather than
    raised, so the rest of the rule set still evaluates.
    """
    by_id = {}
    for rule in rules:
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise loading.ConfigurationError("Every rule needs a nonempty id.")
        if rule_id in by_id:
            raise loading.ConfigurationError("The bundle declares rule %s twice." % rule_id)
        by_id[rule_id] = rule

    problems = {}
    for rule in rules:
        unknown = [
            required
            for required in rule.get("requires") or []
            if required not in by_id
        ]
        if unknown:
            problems[rule["id"]] = (
                "Rule %s requires the unknown rule %s." % (rule["id"], unknown[0]),
                unknown,
            )

    order = []
    placed = set()
    for rule in rules:
        _place(rule["id"], by_id, placed, order, [], problems)
    return order, problems


def _place(rule_id, by_id, placed, order, stack, problems):
    if rule_id in placed:
        return
    if rule_id in stack:
        cycle = stack[stack.index(rule_id):]
        for member in cycle:
            problems.setdefault(
                member,
                (
                    "Rule %s takes part in a dependency cycle through %s."
                    % (member, cycle[(cycle.index(member) + 1) % len(cycle)]),
                    list(cycle),
                ),
            )
        return
    stack.append(rule_id)
    for required in by_id[rule_id].get("requires") or []:
        if required in by_id:
            _place(required, by_id, placed, order, stack, problems)
    stack.pop()
    placed.add(rule_id)
    order.append(rule_id)


def _context(
    document,
    section,
    declarations,
    loaded,
    model_data,
    prepared,
    envelope_findings,
    positions,
    pointers,
    acquisitions,
):
    context = Context()
    if isinstance(prepared, dict):
        context.update(prepared)
    context.update(
        {
            "document": document,
            "bundle": section,
            "bundle_loaded": loaded,
            "declarations": declarations,
            "grammar": document.get("grammar") if isinstance(document, dict) else None,
            "semanticTypes": document.get("semanticTypes")
            if isinstance(document, dict)
            else None,
            "model": model_data,
            "prepared": prepared,
            "envelope_findings": envelope_findings,
            "positions": positions,
            "pointers": pointers,
            "acquisitions": acquisitions,
            "snapshots": {
                input_id: record.get("snapshot")
                for input_id, record in acquisitions.items()
                if record.get("ok")
            },
            "identities": {
                input_id: record.get("identity")
                for input_id, record in acquisitions.items()
                if record.get("ok")
            },
        }
    )
    _alias(context, FIELD_PROBLEM_NAMES)
    _alias(context, DANGLING_NAMES)
    return context


def _alias(context, names):
    """Publish one preparation table under every name a reader may ask for.

    The engine owns the evaluation context, so it is the one place that can
    reconcile the name a preparation table is built under with the name a leaf
    looks it up by, rather than leaving a silent None between them.
    """
    table = None
    for name in names:
        found = context.get(name)
        if isinstance(found, dict) and found:
            table = found
            break
    if table is None:
        table = {}
    for name in names:
        context.setdefault(name, table)


def _unpack(prepared):
    """Read the model and the preparation findings out of build_model's result.

    The model preparation step returns the model itself, carrying its
    preparation findings under ``findings``. A wrapper around the two is
    accepted as well, so the engine reads either shape.
    """
    if isinstance(prepared, tuple):
        listed = list(prepared)
        model_data = listed[0] if listed else None
        found = listed[1] if len(listed) > 1 else []
        return model_data, list(found or [])
    if isinstance(prepared, dict):
        if "records" in prepared or "by_uid" in prepared:
            return prepared, list(prepared.get("findings") or [])
        if "model" in prepared or "findings" in prepared:
            return prepared.get("model"), list(prepared.get("findings") or [])
        return prepared, []
    return prepared, []


def _document(loaded, bundle_path):
    if isinstance(loaded, dict) and isinstance(loaded.get("document"), dict):
        return loaded["document"]
    return loading.read_json(bundle_path)


def _positions(model_data):
    if isinstance(model_data, dict):
        position = model_data.get("position")
        if isinstance(position, dict):
            return position
        records = model_data.get("records")
        if isinstance(records, list):
            return {
                record["uid"]: index
                for index, record in enumerate(records)
                if isinstance(record, dict) and "uid" in record
            }
    return {}


def _baseline_identity(section, rules, acquisitions):
    """The one captured baseline identity the envelope reports.

    The envelope carries a single ``baseline`` field (contract.md:569-570)
    while the bundle may declare several external inputs and step 1 binds each
    of them (contract.md:500-531), so which capture that field reports has to
    be decided rather than assumed. A preserve leaf names its baseline input
    (contract.md:245), so the reported identity is that input's; with no
    preserve leaf it is the first declared input that captured, in bundle
    declaration order.
    """
    preferred = _preserve_baselines(rules)
    for wanted in (preferred, None):
        for declaration in section.get("inputs") or []:
            input_id = declaration.get("id")
            if wanted is not None and input_id not in wanted:
                continue
            acquired = acquisitions.get(input_id)
            if acquired is not None and acquired.get("ok"):
                return acquired.get("identity")
    return None


def _preserve_baselines(rules):
    """The input ids the bundle's preserve leaves name, in traversal order."""
    found = []
    for rule in rules:
        for leaf in _leaves_of(rule.get("check")):
            if leaf.get("kind") != "preserve":
                continue
            baseline = leaf.get("baseline")
            if baseline is not None and baseline not in found:
                found.append(baseline)
    return found


def _leaves_of(check):
    """Every leaf under a check, walking all, any and not (contract.md:741)."""
    if not isinstance(check, dict):
        return
    for operator in OPERATOR_KEYS:
        if operator not in check:
            continue
        children = check[operator]
        for child in children if isinstance(children, list) else [children]:
            yield from _leaves_of(child)
        return
    if "kind" in check:
        yield check


def _rules(declarations, section):
    """The bundle's rule set, with duplicate identities already merged.

    Loading merges two identical definitions of one rule id into a single
    entry carrying both origins, and throws only on a conflicting one
    (contract.md:860-861). Reading the raw bundle list back here would restore
    the duplicate and leave the envelope unable to carry the one entry per
    bundle rule that contract.md:570-573 requires.
    """
    if isinstance(declarations, dict) and isinstance(declarations.get("rules"), list):
        return list(declarations["rules"])
    return list(section.get("rules") or [])


def _acquisition_findings(section, rules, acquisitions):
    """Report a failed required capture that no rule would report.

    A failed acquisition is an execution error for every rule declaring that
    input (contract.md:523-525), so an input some rule consumes is already
    reported on those rules and needs nothing here. An input no rule consumes
    has no such rule, while ``required: true`` still requires a successful
    capture (contract.md:496-498), so that failure is reported at envelope
    level instead (contract.md:661-663, contract.md:817). Without it the
    envelope would stay satisfied and the candidate would be accepted with the
    required capture never having happened (contract.md:665).
    """
    consumed = {
        input_id
        for rule in rules
        for input_id in rule.get("inputs") or []
    }
    found = []
    for declaration in section.get("inputs") or []:
        input_id = declaration.get("id")
        if input_id in consumed:
            continue
        if (declaration.get("config") or {}).get("required") is not True:
            continue
        acquired = acquisitions.get(input_id)
        if acquired is not None and acquired.get("ok"):
            continue
        reason = (
            acquired["failure"]["reason"]
            if acquired is not None
            else "The external input %s was never acquired." % input_id
        )
        found.append(
            _non_leaf_finding(None, "error", "execution", reason, input_id, [])
        )
    return found


def _invocation(invocation_path, candidate_path):
    """Bind the invocation configuration and the provider working directory.

    Provider commands run with the working directory set to the directory that
    supplied the resolved invocation configuration, which is what makes the
    relative paths of contract.md:515-517 resolve.
    """
    if invocation_path is None:
        return {"inputs": {}}, _directory_of(candidate_path)
    return loading.load_invocation(invocation_path), _directory_of(invocation_path)


def _directory_of(path):
    return os.path.dirname(os.path.abspath(path)) or os.curdir


def _default_evaluation(candidate_path):
    return os.path.basename(_directory_of(candidate_path))


def _entry(rule_id, status, entry_findings, causes):
    return {
        "rule": rule_id,
        "status": status,
        "findings": list(entry_findings),
        "causes": _unique(causes),
    }


def _subject_finding(subject, predicate_path, kind, status, code, message, evidence):
    return finding_support.finding(
        subject["uid"],
        _occurrence(subject),
        subject["occurrenceIndex"],
        predicate_path,
        kind,
        status,
        code,
        message,
        evidence,
    )


def _non_leaf_finding(subject, status, code, reason, input_id, requires):
    """Build a non-leaf diagnostic: null predicatePath and null kind."""
    evidence = finding_support.blocked_evidence({}, reason, input_id, list(requires))
    if subject is None:
        return finding_support.finding(
            None, None, None, None, None, status, code, reason, evidence
        )
    return finding_support.finding(
        subject["uid"],
        _occurrence(subject),
        subject["occurrenceIndex"],
        None,
        None,
        status,
        code,
        reason,
        evidence,
    )


def _structural_finding(problem, reason):
    """Name the implicated record when the structural failure carries one.

    A protocol or configuration error uses null uid and occurrence when no
    record is implicated (contract.md:661-663); the candidate shape failure
    carries them when it knows them.
    """
    occurrence = getattr(problem, "occurrence", None)
    if not (isinstance(occurrence, dict) and {"role", "direction", "target"} <= set(occurrence)):
        occurrence = None
    return finding_support.finding(
        getattr(problem, "uid", None),
        occurrence,
        getattr(problem, "occurrence_index", None),
        None,
        None,
        "error",
        "input",
        reason,
        finding_support.blocked_evidence({}, reason, None, []),
    )


def _occurrence(subject):
    occurrence = subject.get("occurrence")
    if not isinstance(occurrence, dict):
        return None
    return {
        "role": occurrence["role"],
        "direction": occurrence["direction"],
        "target": occurrence["target"],
    }


def _leaf_message(kind, status, evidence):
    if isinstance(evidence, dict) and isinstance(evidence.get("reason"), str):
        return evidence["reason"]
    return "The %s check is %s." % (kind, status)


def _unique(values):
    seen = set()
    ordered = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def _section(document):
    if isinstance(document, dict) and isinstance(document.get("bundle"), dict):
        return document["bundle"]
    return document if isinstance(document, dict) else {}


def _bundle_argument(loaded, document):
    if isinstance(loaded, dict) and "semanticTypes" in loaded:
        return loaded
    return document


def _declarations_index(loaded, document):
    if isinstance(loaded, dict):
        for key in ("index", "declarations"):
            candidate = loaded.get(key)
            if isinstance(candidate, dict):
                return candidate
        if "grammar" not in loaded and "bundle" not in loaded:
            return loaded
        if isinstance(loaded.get("declarations"), list):
            return loaded["declarations"]
    return _section(document).get("declarations") or []
