"""External input acquisition.

This is the only module that starts a subprocess. It binds every external
input declaration a rule names to its ``invocation.json`` entry, runs the
bound command exactly once with no stdin and no shell, and turns the whole
failure taxonomy of contract.md:519-531 into one record per input.

The snapshot is captured once per evaluation and handed to the engine, which
reuses it for every rule declaring that input, so a provider that changes
between two rules of one evaluation cannot be observed (contract.md:529-531).
"""

import json
import subprocess

from . import loading

FAILURE_KEYS = ("input", "reason", "requires")


def acquire(bundle, invocation, invocation_dir, declarations=None):
    """Capture every external snapshot the bundle declares.

    Every declared external input is bound and invoked, not only the ones some
    rule names: step 1 binds each external input id (contract.md:519) and
    ``required: true`` requires a successful capture (contract.md:496-498),
    which an input no rule happens to consume would otherwise never attempt.

    Returns a mapping from input declaration id to an acquisition record with
    the keys ``input``, ``ok``, ``identity``, ``snapshot`` and ``failure``.
    ``failure`` is ``None`` on success and otherwise carries exactly the keys
    in ``FAILURE_KEYS``, ready to travel inside a finding's evidence
    (contract.md:639).
    """
    section = _section(bundle)
    bindings = _bindings(invocation)
    expected_model = _model_name(section)
    captured = {}
    for declaration in section.get("inputs") or []:
        input_id = declaration.get("id")
        captured[input_id] = _capture(
            input_id,
            declaration,
            bindings.get(input_id),
            invocation_dir,
            expected_model,
            declarations,
        )
    return captured


def declared_inputs(bundle):
    """Return the set of external input declaration ids the bundle declares."""
    section = _section(bundle)
    return {
        declaration.get("id")
        for declaration in section.get("inputs") or []
        if declaration.get("id") is not None
    }


def _capture(
    input_id,
    declaration,
    binding,
    working_directory,
    expected_model,
    declarations=None,
):
    name = declaration.get("name") or input_id
    if binding is None:
        return _failed(
            input_id,
            "invocation.json declares no binding for %s, so the required "
            "external snapshot was never acquired." % input_id,
        )
    command = binding.get("command")
    timeout = binding.get("timeoutSeconds")
    try:
        finished = subprocess.run(
            list(command),
            cwd=working_directory,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=float(timeout),
            shell=False,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return _failed(
            input_id,
            "The %s command exceeded its %s second timeout."
            % (name, _seconds(timeout)),
        )
    except OSError as problem:
        return _failed(
            input_id,
            "The %s command could not be started: %s." % (name, problem.strerror),
        )
    if finished.returncode != 0:
        return _failed(
            input_id,
            "The %s command exited with status %d." % (name, finished.returncode),
        )
    text = finished.stdout.decode("utf-8", errors="replace")
    if not text.strip():
        return _failed(
            input_id,
            "The %s command wrote no JSON snapshot object to stdout." % name,
        )
    try:
        snapshot = loading.parse_snapshot(text)
    except Exception:
        return _failed(input_id, "The %s command %s." % (name, _decoding_problem(text)))
    if not isinstance(snapshot, dict):
        return _failed(input_id, "The %s command stdout is JSON of the wrong shape." % name)
    problem = _snapshot_problem(snapshot, name, expected_model, declarations)
    if problem is not None:
        return _failed(input_id, problem)
    return {
        "input": input_id,
        "ok": True,
        "identity": snapshot.get("identity"),
        "snapshot": snapshot,
        "failure": None,
    }


def _snapshot_problem(snapshot, name, expected_model, declarations=None):
    """Validate the provider protocol and the snapshot's own record shape.

    Missing or invalid semantic field VALUES are deliberately left alone: a
    baseline is compared exactly and is never defaulted or repaired
    (contract.md:492-494). Declaration NAMES carry no such exemption, so an
    element, field or relation the model does not declare fails the capture
    (contract.md:494-495) rather than surviving into a preserve difference.
    """
    model = snapshot.get("model")
    if not isinstance(model, str) or not model:
        return "The %s snapshot has no model." % name
    if expected_model is not None and model != expected_model:
        return "The %s snapshot declares model %s rather than %s." % (
            name,
            model,
            expected_model,
        )
    identity = snapshot.get("identity")
    if not isinstance(identity, str) or not identity:
        return "The %s snapshot has no identity." % name
    if "complete" not in snapshot:
        return "The %s snapshot does not declare complete:true." % name
    if snapshot.get("complete") is not True:
        return (
            "The %s provider declared complete:false, so the protected set is "
            "not a complete snapshot." % name
        )
    records = snapshot.get("records")
    if not isinstance(records, list):
        return "The %s snapshot has no records list." % name
    if "created" in snapshot:
        return "The %s snapshot carries a created list, which a baseline has not." % name
    seen = set()
    for record in records:
        detail = _record_problem(record, seen, declarations)
        if detail is not None:
            return "The %s snapshot has an invalid record: %s." % (name, detail)
    return None


def _record_problem(record, seen, declarations=None):
    if not isinstance(record, dict):
        return "a record is not an object"
    if set(record) != {"uid", "element", "fields", "relations"}:
        return "a record does not have exactly uid, element, fields and relations"
    uid = record.get("uid")
    if not isinstance(uid, str) or not uid:
        return "a record uid is not a nonempty string"
    if uid in seen:
        return "uid %s appears twice" % uid
    seen.add(uid)
    if not isinstance(record.get("element"), str) or not record["element"]:
        return "the element of %s is not a nonempty string" % uid
    fields = record.get("fields")
    if not isinstance(fields, dict):
        return "the fields of %s are not an object" % uid
    for field_name, values in fields.items():
        if not isinstance(values, list) or not all(
            isinstance(value, str) for value in values
        ):
            return "field %s of %s is not a list of strings" % (field_name, uid)
    if fields.get("UID") != [uid]:
        return "the UID field of %s does not hold its uid" % uid
    relations = record.get("relations")
    if not isinstance(relations, list):
        return "the relations of %s are not a list" % uid
    for occurrence in relations:
        if not isinstance(occurrence, dict) or set(occurrence) != {
            "role",
            "direction",
            "target",
        }:
            return "an occurrence of %s does not have exactly role, direction and target" % uid
        for key in ("role", "target"):
            if not isinstance(occurrence.get(key), str) or not occurrence[key]:
                return "the %s of an occurrence of %s is not a nonempty string" % (key, uid)
        if occurrence.get("direction") not in ("parent", "child"):
            return "an occurrence of %s has an undeclared direction" % uid
    return _undeclared_name(record, declarations)


def _undeclared_name(record, declarations):
    """Name the first element, field or relation the model does not declare.

    A baseline record uses exactly the candidate record shape
    (contract.md:485-486) and candidate records resolve their element, field
    and relation names in the declarations index (contract.md:847-852), so a
    baseline resolves them the same way.
    """
    if not isinstance(declarations, dict):
        return None
    uid = record["uid"]
    element = declarations.get("elements", {}).get(record["element"])
    if element is None:
        return "the element of %s is not declared" % uid
    element_id = element["id"]
    for field_name in record["fields"]:
        if (element_id, field_name) not in declarations.get("fields", {}):
            return "the field %s of %s is not declared" % (field_name, uid)
    for occurrence in record["relations"]:
        key = (element_id, occurrence["direction"], occurrence["role"])
        if key not in declarations.get("relations", {}):
            return "the %s relation %s of %s is not declared" % (
                occurrence["direction"],
                occurrence["role"],
                uid,
            )
    return None


def _decoding_problem(text):
    """Say whether unparsable provider output is not JSON or the wrong shape."""
    try:
        decoded = json.loads(text)
    except ValueError:
        return "stdout is not JSON"
    if not isinstance(decoded, dict):
        return "stdout is JSON of the wrong shape"
    return "stdout is not a valid JSON snapshot object"


def _failed(input_id, reason):
    return {
        "input": input_id,
        "ok": False,
        "identity": None,
        "snapshot": None,
        "failure": {"input": input_id, "reason": reason, "requires": []},
    }


def _seconds(value):
    try:
        return "%g" % float(value)
    except (TypeError, ValueError):
        return str(value)


def _section(bundle):
    if isinstance(bundle, dict) and isinstance(bundle.get("bundle"), dict):
        return bundle["bundle"]
    return bundle if isinstance(bundle, dict) else {}


def _bindings(invocation):
    if isinstance(invocation, dict) and isinstance(invocation.get("inputs"), dict):
        return invocation["inputs"]
    return {}


def _model_name(section):
    for declaration in section.get("declarations") or []:
        if declaration.get("kind") == "model":
            return declaration.get("name")
    return None
