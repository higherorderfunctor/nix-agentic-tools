"""Reading and indexing every configuration file.

This is the only module that raises for a malformed configuration. It decodes
JSON with a pairs hook that rejects duplicate object keys rather than keeping
one value (contract.md:448), builds the declarations name-to-id index exactly as
contract.md:847-852 prescribes, validates the closed keyword spaces of
contract.md:765-779, rejects unknown leaf kinds, unknown operator keys, extra
check keys and invalid shapes (contract.md:247-250, contract.md:797-798), checks
each ``semanticTypes[].fields[].native`` against the grammar body of the same
field (contract.md:958-960), and never recomputes ``digest``
(contract.md:1015).

``load_bundle`` returns ONE dict, so the caller keeps a single value:

    document        the whole decoded document holding grammar, semanticTypes
                    and bundle (contract.md:110-116)
    bundle          the bundle section of that document
    grammar         the authoritative native grammar entries
    semanticTypes   the derived semantic metadata entries
    index           the declarations index every other module reads
    declarations    the same index, under the name a caller may expect

The index is a plain dict, so a caller may either use the lookup helpers below
or read a member such as ``index["rules"]`` directly.
"""

import json
import math
import os

# The complete allowed value space for each keyword field in this profile
# (contract.md:765-779). Booleans are JSON booleans, not quoted strings.
KEYWORD_SPACES = {
    "ascent": ["unrestricted"],
    "visit": ["always"],
    "expand": ["open-or-origin-in-subtree-including-self"],
    "orientation": ["parent-to-child"],
    "connected": [False],
    "relationOrder": ["set"],
    "requireSingleton": [True],
    "from": ["owner"],
    "to": ["target"],
    "subject": ["record", "owner", "target"],
    "absentSatisfies": [False, True],
    "compare": ["lt", "lte", "gt", "gte", "eq"],
    "direction": ["parent", "child"],
    "status": ["satisfied", "violated", "blocked", "error"],
}

# Leaf kind to the exact key set a check object of that kind carries, and the
# selectors the leaf is valid for (contract.md:237-252). The kinds are kept in
# the contract table's own order rather than alphabetically, because that table
# is what this one restates. Every kind names a tuple of selectors, and only
# field-value has more than one: it reads a field of the selected record, of an
# occurrence owner or of an occurrence target, so its own subject keyword is
# what decides which selector it belongs under.
LEAF_SHAPES = {
    "target-type": (("kind", "targetElement"), ("occurrences",)),
    "count": (("kind", "relation", "compare", "value"), ("records",)),
    "field-value": (
        ("kind", "field", "subject", "values", "absentSatisfies"),
        ("records", "occurrences"),
    ),
    "visible-target": (("kind", "view", "from", "to"), ("occurrences",)),
    "endpoint-path": (
        ("kind", "view", "upper", "lower", "requireSingleton"),
        ("records",),
    ),
    "native-dag": (("kind",), ("model",)),
    "forest-validity": (("kind", "view"), ("model",)),
    "preserve": (("kind", "baseline", "projection"), ("model",)),
}

# The subject a field-value leaf may name under each selector. A records
# selector fixes the element, so the only subject is the selected record; an
# occurrences selector binds the two endpoints of the occurrence instead.
FIELD_VALUE_SUBJECTS = {
    "records": ("record",),
    "occurrences": ("owner", "target"),
}

# The closed operator keys; they are not kinds (contract.md:786).
OPERATOR_KEYS = ("all", "any", "not")

# Declaration kinds inside bundle.declarations (contract.md:786-787).
DECLARATION_KINDS = ("model", "element", "relation", "field")

# The only supported schema strings.
BUNDLE_SCHEMA = "semantic-constraints/v2"
SEMANTIC_TYPES_SCHEMA = "semantic-types/v1"
INPUT_CONFIG_KIND = "external-snapshot"
VIEW_CONTRACTS = ("selected-forest/v1", "origin-sensitive-visibility/v1")
DEFAULTS_LIFECYCLE = "surviving-new-record-final-absence-only"
RELATION_PROJECTION = ["nativeType", "role", "target"]

# The one native field type key space of this packet (contract.md:960-964).
NATIVE_TYPE_KEYS = ("string", "singleChoice")


class ConfigurationError(Exception):
    """A configuration or protocol failure (contract.md:816).

    Raised for an unreadable or malformed bundle, invocation configuration or
    provider snapshot, and for any unsupported keyword value, unknown leaf
    kind, unknown operator key, extra check key or invalid shape.
    """


class CandidateShapeError(Exception):
    """A candidate structural failure that prevents indexing.

    The engine turns this into an error envelope finding and blocks every
    candidate-dependent rule with cause ``candidate`` (contract.md:657-658,
    contract.md:625-628). The optional members let the engine name the record
    or occurrence that is implicated.
    """

    def __init__(self, message, uid=None, occurrence=None, occurrence_index=None):
        super().__init__(message)
        self.message = message
        self.uid = uid
        self.occurrence = occurrence
        self.occurrence_index = occurrence_index


def reject_duplicate_keys(pairs):
    """Object pairs hook that rejects a duplicate key (contract.md:448-449)."""
    built = {}
    for key, value in pairs:
        if key in built:
            raise ValueError("duplicate JSON object key " + repr(key))
        built[key] = value
    return built


def decode_json(text, origin):
    """Decode one JSON document, rejecting duplicate object keys."""
    try:
        return json.loads(text, object_pairs_hook=reject_duplicate_keys)
    except ValueError as problem:
        raise ConfigurationError(origin + " is not valid JSON: " + str(problem))


def read_json(path):
    """Read and decode one JSON file, rejecting duplicate object keys."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as problem:
        raise ConfigurationError("cannot read " + str(path) + ": " + str(problem))
    return decode_json(text, str(path))


def parse_snapshot(text):
    """Decode a provider snapshot from captured standard output.

    Standard output must hold exactly one JSON snapshot object with optional
    surrounding whitespace (contract.md:520-522). Anything else raises
    ConfigurationError, which the provider runner turns into one execution
    failure (contract.md:523-525).
    """
    stripped = text.strip()
    if not stripped:
        raise ConfigurationError("the provider wrote no JSON snapshot")
    snapshot = decode_json(stripped, "the provider snapshot")
    if not isinstance(snapshot, dict):
        raise ConfigurationError("the provider snapshot is not a JSON object")
    return snapshot


def validate_keyword(field, value):
    """Reject an unsupported keyword value, naming the field and the value."""
    space = KEYWORD_SPACES.get(field)
    if space is None:
        return value
    for allowed in space:
        if type(allowed) is type(value) and allowed == value:
            return value
    raise ConfigurationError(
        "the " + field + " keyword rejects the value " + repr(value)
    )


def expect_object(value, what):
    if not isinstance(value, dict):
        raise ConfigurationError(what + " must be a JSON object")
    return value


def expect_list(value, what):
    if not isinstance(value, list):
        raise ConfigurationError(what + " must be a JSON array")
    return value


def expect_text(value, what):
    if not isinstance(value, str) or not value:
        raise ConfigurationError(what + " must be a nonempty string")
    return value


def expect_keys(value, keys, what):
    """Require exactly the given key set, naming any missing or extra key."""
    expect_object(value, what)
    present = set(value)
    wanted = set(keys)
    missing = sorted(wanted - present)
    extra = sorted(present - wanted)
    if missing:
        raise ConfigurationError(what + " is missing " + ", ".join(missing))
    if extra:
        raise ConfigurationError(what + " carries unsupported " + ", ".join(extra))
    return value


def load_bundle(path):
    """Read bundle.json and build the declarations index."""
    document = expect_object(read_json(path), "the bundle document")
    for member in ("grammar", "semanticTypes", "bundle"):
        if member not in document:
            raise ConfigurationError("the bundle document is missing " + member)
    bundle = expect_object(document["bundle"], "bundle")
    if bundle.get("schema") != BUNDLE_SCHEMA:
        raise ConfigurationError(
            "bundle.schema must be " + BUNDLE_SCHEMA + ", not " + repr(bundle.get("schema"))
        )
    declarations = index_declarations(document, bundle)
    validate_grammar_agreement(document, declarations)
    validate_rules(bundle, declarations)
    validate_prerequisite_shapes(declarations)
    return {
        "document": document,
        "bundle": bundle,
        "grammar": document["grammar"],
        "semanticTypes": document["semanticTypes"],
        "index": declarations,
        "declarations": declarations,
    }


def index_declarations(document, bundle):
    """Build the name-to-id index of contract.md:847-852 and the id maps."""
    index = {
        "document": document,
        "bundle": bundle,
        "grammar": expect_list(document["grammar"], "grammar"),
        "semanticTypes": expect_list(document["semanticTypes"], "semanticTypes"),
        "model_id": expect_text(bundle.get("id"), "bundle.id"),
        "model_name": None,
        "models": {},
        "elements": {},
        "element_by_id": {},
        "fields": {},
        "field_by_id": {},
        "relations": {},
        "relation_by_id": {},
        "views": {},
        "inputs": {},
        "projections": {},
        "rules": [],
        "rule_by_id": {},
        "grammar_by_tag": {},
        "semantic_by_element_id": {},
    }
    for declaration in expect_list(
        bundle.get("declarations"), "bundle.declarations"
    ):
        expect_object(declaration, "a declaration")
        kind = declaration.get("kind")
        identity = expect_text(declaration.get("id"), "a declaration id")
        name = expect_text(declaration.get("name"), "a declaration name")
        if kind not in DECLARATION_KINDS:
            raise ConfigurationError("unsupported declaration kind " + repr(kind))
        if kind == "model":
            index["models"][name] = declaration
        elif kind == "element":
            if name in index["elements"]:
                raise ConfigurationError("element name " + name + " is not unique")
            index["elements"][name] = declaration
            index["element_by_id"][identity] = declaration
        elif kind == "field":
            owner = expect_text(declaration.get("owner"), "a field owner")
            index["fields"][(owner, name)] = declaration
            index["field_by_id"][identity] = declaration
        else:
            owner = expect_text(declaration.get("owner"), "a relation owner")
            direction = validate_keyword("direction", declaration.get("direction"))
            index["relations"][(owner, direction, name)] = declaration
            index["relation_by_id"][identity] = declaration
    for name, declaration in index["models"].items():
        if declaration["id"] == index["model_id"]:
            index["model_name"] = name
    if index["model_name"] is None:
        raise ConfigurationError(
            "bundle.declarations has no model declaration for " + index["model_id"]
        )
    index_named_lists(bundle, index)
    for entry in index["grammar"]:
        expect_object(entry, "a grammar entry")
        tag = expect_text(entry.get("tag"), "a grammar tag")
        index["grammar_by_tag"][tag] = entry
    for entry in index["semanticTypes"]:
        expect_object(entry, "a semanticTypes entry")
        if entry.get("schema") != SEMANTIC_TYPES_SCHEMA:
            raise ConfigurationError(
                "a semanticTypes entry must carry schema " + SEMANTIC_TYPES_SCHEMA
            )
        if entry.get("grammar") != index["model_id"]:
            raise ConfigurationError(
                "a semanticTypes entry must name the bundle model as its grammar"
            )
        if entry.get("defaultsApply") != DEFAULTS_LIFECYCLE:
            raise ConfigurationError(
                "unsupported defaultsApply " + repr(entry.get("defaultsApply"))
            )
        element_id = expect_text(entry.get("element"), "a semanticTypes element")
        if element_id not in index["element_by_id"]:
            raise ConfigurationError("unknown semanticTypes element " + element_id)
        index["semantic_by_element_id"][element_id] = entry
    return index


def index_named_lists(bundle, index):
    """Index bundle.views, bundle.inputs and bundle.projections by id."""
    for view in expect_list(bundle.get("views", []), "bundle.views"):
        expect_object(view, "a view")
        if view.get("kind") != "view":
            raise ConfigurationError("a bundle.views entry must have kind view")
        config = expect_object(view.get("config"), "a view config")
        if config.get("contract") not in VIEW_CONTRACTS:
            raise ConfigurationError(
                "unsupported view contract " + repr(config.get("contract"))
            )
        if config["contract"] == "selected-forest/v1":
            expect_keys(
                config,
                ("connected", "contract", "edges", "orientation", "vertices"),
                "a selected forest view config",
            )
            validate_keyword("connected", config["connected"])
            validate_keyword("orientation", config["orientation"])
        else:
            expect_keys(
                config,
                ("contract", "hierarchy", "policy"),
                "a visibility view config",
            )
            policy = expect_keys(
                config["policy"],
                ("ascent", "closedWhenTrue", "expand", "visit"),
                "a visibility policy",
            )
            for field in ("ascent", "expand", "visit"):
                validate_keyword(field, policy[field])
            if policy["closedWhenTrue"] not in index["field_by_id"]:
                raise ConfigurationError(
                    "unknown visibility closedWhenTrue field "
                    + str(policy["closedWhenTrue"])
                )
        index["views"][expect_text(view.get("id"), "a view id")] = view
    validate_view_hierarchies(index)
    for declaration in expect_list(bundle.get("inputs", []), "bundle.inputs"):
        expect_object(declaration, "an input declaration")
        if declaration.get("kind") != "input":
            raise ConfigurationError("a bundle.inputs entry must have kind input")
        config = expect_keys(
            declaration.get("config"),
            ("complete", "kind", "required"),
            "an input config",
        )
        if config["kind"] != INPUT_CONFIG_KIND:
            raise ConfigurationError(
                "unsupported input config kind " + repr(config["kind"])
            )
        for field in ("complete", "required"):
            if config[field] is not True:
                raise ConfigurationError("input " + field + " has only true")
        index["inputs"][
            expect_text(declaration.get("id"), "an input id")
        ] = declaration
    for projection in expect_list(
        bundle.get("projections", []), "bundle.projections"
    ):
        expect_object(projection, "a projection")
        if projection.get("kind") != "projection":
            raise ConfigurationError(
                "a bundle.projections entry must have kind projection"
            )
        config = expect_keys(
            projection.get("config"),
            (
                "element",
                "existence",
                "fieldPresence",
                "fields",
                "key",
                "ownedRelations",
                "relationOrder",
                "relationProjection",
            ),
            "a projection config",
        )
        for field in ("element", "existence", "fieldPresence"):
            if config[field] is not True:
                raise ConfigurationError("projection " + field + " has only true")
        validate_keyword("relationOrder", config["relationOrder"])
        if config["relationProjection"] != RELATION_PROJECTION:
            raise ConfigurationError(
                "relationProjection must be exactly "
                + json.dumps(RELATION_PROJECTION)
            )
        for field_id in expect_list(config["fields"], "projection fields"):
            if field_id not in index["field_by_id"]:
                raise ConfigurationError("unknown projection field " + str(field_id))
        for relation_id in expect_list(
            config["ownedRelations"], "projection ownedRelations"
        ):
            if relation_id not in index["relation_by_id"]:
                raise ConfigurationError(
                    "unknown projection relation " + str(relation_id)
                )
        index["projections"][
            expect_text(projection.get("id"), "a projection id")
        ] = projection


def validate_view_hierarchies(index):
    """Resolve each visibility view's hierarchy in bundle.views.

    ``hierarchy`` is a declaration id and a view id resolves in bundle.views
    (contract.md:853-856), and the hierarchy it names must be a selected
    forest, because the visibility walk reads that forest's parents
    (contract.md:298-301). Resolution runs after every view is indexed, so a
    visibility view may name a forest declared after it. Left unresolved, the
    unknown id reaches the leaf and aborts the run with no envelope at all
    instead of the configuration error of contract.md:816.
    """
    for view in index["views"].values():
        config = view["config"]
        if config["contract"] != "origin-sensitive-visibility/v1":
            continue
        hierarchy = index["views"].get(config["hierarchy"])
        if hierarchy is None:
            raise ConfigurationError(
                "unknown visibility hierarchy view " + str(config["hierarchy"])
            )
        if hierarchy["config"]["contract"] != "selected-forest/v1":
            raise ConfigurationError(
                "the visibility hierarchy " + str(config["hierarchy"])
                + " is not a selected forest view"
            )


def validate_grammar_agreement(document, index):
    """Check each semanticTypes native body against the grammar body.

    ``grammar`` is authoritative for native field validation; a derived
    restatement that disagrees is a configuration error (contract.md:957-960).
    """
    for element_id, entry in index["semantic_by_element_id"].items():
        element_name = index["element_by_id"][element_id]["name"]
        grammar_entry = index["grammar_by_tag"].get(element_name)
        if grammar_entry is None:
            raise ConfigurationError(
                "the grammar has no entry tagged " + element_name
            )
        bodies = grammar_field_bodies(grammar_entry, element_name)
        for field in expect_list(entry.get("fields"), "semanticTypes fields"):
            expect_keys(
                field,
                ("default", "field", "native", "semantic"),
                "a semanticTypes field",
            )
            field_id = expect_text(field["field"], "a semanticTypes field id")
            declaration = index["field_by_id"].get(field_id)
            if declaration is None or declaration.get("owner") != element_id:
                raise ConfigurationError(
                    "the semanticTypes field " + field_id + " is not declared on "
                    + element_name
                )
            field_name = declaration["name"]
            if field_name not in bodies:
                raise ConfigurationError(
                    "the grammar of " + element_name + " has no field " + field_name
                )
            if field["native"] != bodies[field_name]:
                raise ConfigurationError(
                    "the semanticTypes native body of "
                    + element_name
                    + "."
                    + field_name
                    + " disagrees with the grammar"
                )
            validate_semantic_body(field, element_name, field_name)


def grammar_field_bodies(grammar_entry, element_name):
    """Map each grammar field name to its one-type-key body."""
    bodies = {}
    for body in expect_list(grammar_entry.get("fields", []), "grammar fields"):
        expect_object(body, "a grammar field")
        if len(body) != 1:
            raise ConfigurationError("a grammar field body has one type key")
        type_key = next(iter(body))
        if type_key not in NATIVE_TYPE_KEYS:
            raise ConfigurationError("unsupported native field type " + type_key)
        inner = expect_object(body[type_key], "a grammar field body")
        title = expect_text(inner.get("title"), "a grammar field title")
        if not isinstance(inner.get("required"), bool):
            raise ConfigurationError(
                "the required member of " + element_name + "." + title
                + " must be a JSON boolean"
            )
        if type_key == "singleChoice":
            choices = expect_list(inner.get("choices"), "singleChoice choices")
            for choice in choices:
                if not isinstance(choice, str):
                    raise ConfigurationError("a singleChoice choice must be a string")
        bodies[title] = body
    return bodies


def validate_semantic_body(field, element_name, field_name):
    """Check a semantic description and its typed default literal."""
    semantic = expect_object(field["semantic"], "a semantic description")
    semantic_type = semantic.get("type")
    if semantic_type == "string":
        expect_keys(semantic, ("type",), "a string semantic description")
    elif semantic_type == "boolean":
        expect_keys(semantic, ("codec", "type"), "a boolean semantic description")
        for entry in expect_list(semantic["codec"], "a boolean codec"):
            expect_keys(entry, ("native", "semantic"), "a codec entry")
            expect_text(entry["native"], "a codec native string")
            if not isinstance(entry["semantic"], bool):
                raise ConfigurationError("a codec semantic value must be a boolean")
    else:
        raise ConfigurationError(
            "unsupported semantic type " + repr(semantic_type) + " on "
            + element_name + "." + field_name
        )
    default = field["default"]
    if default is None:
        return
    expect_keys(default, ("literal",), "a field default")
    encode_literal(field, default["literal"])


def encode_literal(field, literal):
    """Encode a typed default literal into its native string.

    A string uses its single native string directly; a boolean encodes through
    the codec, where only the declared native strings decode
    (contract.md:970-974).
    """
    semantic = field["semantic"]
    if semantic["type"] == "string":
        if not isinstance(literal, str):
            raise ConfigurationError("a string default literal must be a string")
        return literal
    if not isinstance(literal, bool):
        raise ConfigurationError("a boolean default literal must be a boolean")
    for entry in semantic["codec"]:
        if entry["semantic"] is literal:
            return entry["native"]
    raise ConfigurationError(
        "the codec cannot encode the default literal " + repr(literal)
    )


def validate_rules(bundle, index):
    """Validate every rule, merging identical duplicate identities."""
    for rule in expect_list(bundle.get("rules"), "bundle.rules"):
        expect_keys(
            rule,
            ("check", "id", "inputs", "name", "origins", "requires", "select"),
            "a rule",
        )
        identity = expect_text(rule["id"], "a rule id")
        expect_text(rule["name"], "a rule name")
        for member in ("inputs", "requires", "origins"):
            expect_list(rule[member], "rule " + member)
        for input_id in rule["inputs"]:
            if input_id != "candidate" and input_id not in index["inputs"]:
                raise ConfigurationError(
                    "the rule " + identity + " names the unknown input "
                    + str(input_id)
                )
        selector, element = validate_selector(rule["select"], index, identity)
        validate_check(rule["check"], selector, element, index, identity)
        if "where" in rule["select"]:
            validate_check(
                rule["select"]["where"], selector, element, index, identity
            )
        earlier = index["rule_by_id"].get(identity)
        if earlier is None:
            index["rule_by_id"][identity] = rule
            index["rules"].append(rule)
        else:
            merge_rule_origins(earlier, rule, identity)


def validate_prerequisite_shapes(index):
    """Check each rule's ``requires`` against what its leaves mandate.

    contract.md:733-748 fixes the prerequisite set a leaf earns rather than
    leaving it to the author: an endpoint-path leaf needs one standalone
    ``eq`` 1 count rule per endpoint selector on the same element, and both
    endpoint-path and visible-target need the forest-validity rule for their
    visibility hierarchy. A missing or ambiguous match throws naming the
    endpoint, and the lowering may not invent a check instead
    (contract.md:740).

    A backend consuming an externally supplied bundle has to repeat the check,
    because the whole guarantee behind it is evaluation-time: a usable
    hierarchy requires the entire forest-validity rule to be satisfied
    (contract.md:300-301), and only the prerequisite edge makes the dependent
    rule blocked rather than reporting a substantive verdict read off an
    invalid forest (contract.md:749-753).
    """
    for rule in index["rules"]:
        required = rule["requires"]
        for leaf in rule_leaves(rule):
            kind = leaf["kind"]
            if kind == "endpoint-path":
                element = rule["select"]["records"]["element"]
                for endpoint in ("upper", "lower"):
                    require_prerequisite(
                        endpoint_count_rule(index, rule, element, leaf, endpoint),
                        rule,
                        required,
                        "the " + endpoint + " endpoint count",
                    )
            if kind in ("endpoint-path", "visible-target"):
                require_prerequisite(
                    forest_validity_rule(index, rule, leaf["view"]),
                    rule,
                    required,
                    "the forest validity of its hierarchy",
                )


def rule_leaves(rule):
    """Every leaf of a rule's check and of its filter (contract.md:741-743)."""
    for leaf, _ in walk_leaves(rule["check"]):
        yield leaf
    if "where" in rule["select"]:
        for leaf, _ in walk_leaves(rule["select"]["where"]):
            yield leaf


def walk_leaves(check, under_all_only=True):
    """Yield each leaf with whether only ``all`` operators lead to it.

    A forest prerequisite leaf establishes its fact only when it is
    standalone or under ``all`` operators, because a satisfied ``any`` or
    ``not`` does not establish it (contract.md:745-747).
    """
    for operator in OPERATOR_KEYS:
        if operator not in check:
            continue
        children = [check["not"]] if operator == "not" else check[operator]
        for child in children:
            yield from walk_leaves(child, under_all_only and operator == "all")
        return
    yield check, under_all_only


def endpoint_count_rule(index, rule, element, leaf, endpoint):
    """The one standalone count rule an endpoint selector needs."""
    selector = leaf[endpoint]
    wanted = {
        "kind": "count",
        "relation": {
            "direction": selector["direction"],
            "role": selector["role"],
        },
        "compare": "eq",
        "value": 1,
    }
    found = [
        other["id"]
        for other in index["rules"]
        if other["id"] != rule["id"]
        and "where" not in other["select"]
        and other["select"].get("records", {}).get("element") == element
        and other["check"] == wanted
    ]
    if len(found) != 1:
        raise ConfigurationError(
            "the " + endpoint + " endpoint of " + rule["id"]
            + " needs exactly one unfiltered count rule over " + element
            + " comparing its " + selector["direction"] + " " + selector["role"]
            + " occurrences equal to one, and " + str(len(found)) + " rules match"
        )
    return found[0]


def forest_validity_rule(index, rule, view_id):
    """The one forest-validity rule a visibility hierarchy needs."""
    hierarchy = view(index, view_id)["config"]["hierarchy"]
    found = []
    for other in index["rules"]:
        if other["id"] == rule["id"] or "where" in other["select"]:
            continue
        if other["select"].get("model") is not True:
            continue
        for leaf, under_all_only in walk_leaves(other["check"]):
            if (
                under_all_only
                and leaf.get("kind") == "forest-validity"
                and leaf.get("view") == hierarchy
            ):
                found.append(other["id"])
                break
    if len(found) != 1:
        raise ConfigurationError(
            "a leaf of " + rule["id"] + " needs exactly one unfiltered rule "
            "establishing the forest validity of " + str(hierarchy) + ", and "
            + str(len(found)) + " rules match"
        )
    return found[0]


def require_prerequisite(prerequisite, rule, required, what):
    """Require the derived prerequisite to be listed in ``requires``."""
    if prerequisite not in required:
        raise ConfigurationError(
            "the rule " + rule["id"] + " needs " + what + ", so it must require "
            + prerequisite
        )


def merge_rule_origins(earlier, repeated, identity):
    """Merge origins for one identity, or throw on a conflicting definition."""
    for member in ("check", "inputs", "name", "requires", "select"):
        if earlier[member] != repeated[member]:
            raise ConfigurationError(
                "the duplicate rule identity " + identity + " conflicts on " + member
            )
    for origin in repeated["origins"]:
        if origin not in earlier["origins"]:
            earlier["origins"].append(origin)


def validate_selector(select, index, identity):
    """Validate one selector and return its kind and the element it fixes.

    The element is None for a model selector, which names none. Every other
    selector fixes one element for every leaf beneath it, which is what lets a
    leaf naming a field name be resolved against a declaration at load time.
    """
    expect_object(select, "the selector of " + identity)
    chosen = [key for key in ("records", "occurrences", "model") if key in select]
    if len(chosen) != 1:
        raise ConfigurationError(
            "the selector of " + identity
            + " must have exactly one of records, occurrences or model"
        )
    extra = sorted(set(select) - set(chosen) - {"where"})
    if extra:
        raise ConfigurationError(
            "the selector of " + identity + " carries unsupported "
            + ", ".join(extra)
        )
    kind = chosen[0]
    body = select[kind]
    if kind == "model":
        if body is not True:
            raise ConfigurationError("select.model has only true")
        return kind, None
    if kind == "records":
        expect_keys(body, ("element",), "select.records of " + identity)
    else:
        expect_keys(
            body,
            ("direction", "element", "role"),
            "select.occurrences of " + identity,
        )
        validate_keyword("direction", body["direction"])
        expect_text(body["role"], "select.occurrences.role")
    element = expect_text(body["element"], "a selector element name")
    if element not in index["elements"]:
        raise ConfigurationError(
            "the selector of " + identity + " names the unknown element " + element
        )
    if kind == "occurrences":
        owner = index["elements"][element]["id"]
        if relation_of(index, owner, body["direction"], body["role"]) is None:
            raise ConfigurationError(
                "the selector of " + identity + " names an undeclared relation on "
                + element
            )
    return kind, element


def validate_check(check, selector, element, index, identity):
    """Validate one check expression against the closed grammar."""
    expect_object(check, "a check of " + identity)
    operators = [key for key in OPERATOR_KEYS if key in check]
    if operators:
        if len(check) != 1:
            raise ConfigurationError(
                "a check of " + identity + " is exactly one leaf or one operator key"
            )
        operator = operators[0]
        if operator == "not":
            validate_check(check["not"], selector, element, index, identity)
            return
        for child in expect_list(check[operator], operator + " of " + identity):
            validate_check(child, selector, element, index, identity)
        return
    if "kind" not in check:
        raise ConfigurationError(
            "a check of " + identity + " is neither a named leaf nor an operator"
        )
    kind = check["kind"]
    shape = LEAF_SHAPES.get(kind)
    if shape is None:
        raise ConfigurationError("unknown leaf kind " + repr(kind))
    keys, wanted_selectors = shape
    expect_keys(check, keys, "the " + kind + " leaf of " + identity)
    if selector not in wanted_selectors:
        raise ConfigurationError(
            "the " + kind + " leaf of " + identity + " is not valid under a "
            + selector + " selector; it needs " + " or ".join(wanted_selectors)
        )
    validate_leaf_references(check, kind, selector, element, index, identity)


def validate_leaf_references(check, kind, selector, element, index, identity):
    """Resolve the declaration ids and keywords one leaf names."""
    if kind == "target-type":
        if check["targetElement"] not in index["element_by_id"]:
            raise ConfigurationError(
                "the target-type leaf of " + identity + " names the unknown element "
                + str(check["targetElement"])
            )
    elif kind == "count":
        expect_keys(
            check["relation"], ("direction", "role"), "a count relation"
        )
        validate_keyword("direction", check["relation"]["direction"])
        expect_text(check["relation"]["role"], "a count relation role")
        validate_keyword("compare", check["compare"])
        if not isinstance(check["value"], int) or isinstance(check["value"], bool):
            raise ConfigurationError("a count value must be an integer")
    elif kind == "field-value":
        validate_keyword("subject", check["subject"])
        validate_keyword("absentSatisfies", check["absentSatisfies"])
        allowed = FIELD_VALUE_SUBJECTS[selector]
        if check["subject"] not in allowed:
            raise ConfigurationError(
                "the field-value leaf of " + identity + " names the subject "
                + check["subject"] + ", which the " + selector
                + " selector does not bind"
            )
        values = expect_list(check["values"], "field-value values")
        if not values:
            raise ConfigurationError(
                "the field-value leaf of " + identity + " needs at least one value"
            )
        for value in values:
            expect_text(value, "a field-value value of " + identity)
        field_name = expect_text(check["field"], "a field-value field name")
        require_field(
            index, check["subject"], element, field_name, identity
        )
    elif kind == "visible-target":
        validate_keyword("from", check["from"])
        validate_keyword("to", check["to"])
        require_view(index, check["view"], identity)
    elif kind == "endpoint-path":
        validate_keyword("requireSingleton", check["requireSingleton"])
        for endpoint in ("upper", "lower"):
            expect_keys(
                check[endpoint], ("direction", "role"), "an endpoint selector"
            )
            validate_keyword("direction", check[endpoint]["direction"])
            expect_text(check[endpoint]["role"], "an endpoint role")
        require_view(index, check["view"], identity)
    elif kind == "forest-validity":
        require_view(index, check["view"], identity)
    elif kind == "preserve":
        if check["baseline"] not in index["inputs"]:
            raise ConfigurationError(
                "the preserve leaf of " + identity + " names the unknown input "
                + str(check["baseline"])
            )
        if check["projection"] not in index["projections"]:
            raise ConfigurationError(
                "the preserve leaf of " + identity
                + " names the unknown projection " + str(check["projection"])
            )


def require_field(index, subject, element, field_name, identity):
    """Resolve the field NAME a field-value leaf carries.

    A field-value leaf names a field by name rather than by declaration id,
    because the TARGET subject's element is not fixed at lowering time
    (contract.md:912-913). The selector fixes the element of every other
    subject: a records selector fixes the record, and an occurrences selector
    fixes the owner. Naming a field that element does not declare is therefore
    refused here, for the owner subject exactly as for the record subject. Only
    a target subject falls back to the name existing somewhere, and a target
    whose own element lacks it blocks that leaf at evaluation instead.
    """
    if subject != "target":
        owner = index["elements"][element]["id"]
        if field_of(index, owner, field_name) is None:
            raise ConfigurationError(
                "the field-value leaf of " + identity + " names the field "
                + field_name + ", which " + element + " does not declare"
            )
        return
    if not any(name == field_name for _, name in index["fields"]):
        raise ConfigurationError(
            "the field-value leaf of " + identity + " names the undeclared field "
            + field_name
        )


def require_view(index, view_id, identity):
    if view_id not in index["views"]:
        raise ConfigurationError(
            "a leaf of " + identity + " names the unknown view " + str(view_id)
        )


def load_invocation(path):
    """Read invocation.json and validate its binding shape.

    The only top-level member is ``inputs``; each binding has exactly a
    nonempty ``command`` array of strings and a positive finite
    ``timeoutSeconds`` (contract.md:511-514). The corpus uses 0.1 seconds at
    script-default-source-success-vs-failure-family/provider-timeout-refuses,
    so the number is a float rather than an integer.
    """
    document = expect_keys(read_json(path), ("inputs",), "the invocation document")
    bindings = expect_object(document["inputs"], "invocation inputs")
    for input_id, binding in bindings.items():
        where = "the binding of " + str(input_id)
        expect_keys(binding, ("command", "timeoutSeconds"), where)
        command = expect_list(binding["command"], where + " command")
        if not command:
            raise ConfigurationError(where + " command must be nonempty")
        for word in command:
            if not isinstance(word, str):
                raise ConfigurationError(where + " command holds only strings")
        timeout = binding["timeoutSeconds"]
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
            raise ConfigurationError(where + " timeoutSeconds must be a number")
        if not math.isfinite(timeout) or timeout <= 0:
            raise ConfigurationError(
                where + " timeoutSeconds must be positive and finite"
            )
    return document


def element_named(index, name):
    """Look up an element declaration by kind and name (contract.md:850-851)."""
    return index["elements"].get(name)


def field_of(index, element_id, name):
    """Look up a field by owner element id and name (contract.md:851-852)."""
    return index["fields"].get((element_id, name))


def relation_of(index, element_id, direction, role):
    """Look up a relation by owner element id, direction and name."""
    return index["relations"].get((element_id, direction, role))


def view(index, view_id):
    """Resolve a view declaration id in bundle.views."""
    found = index["views"].get(view_id)
    if found is None:
        raise ConfigurationError("unknown view " + str(view_id))
    return found


def semantic_fields(index, element_name):
    """The semanticTypes field entries of one element, in declared order."""
    element = element_named(index, element_name)
    if element is None:
        return []
    entry = index["semantic_by_element_id"].get(element["id"])
    if entry is None:
        return []
    return entry["fields"]


def native_fields(index, element_name):
    """Map each declared field name of one element to its native body.

    The grammar is authoritative for native field validation
    (contract.md:957-958), so this reads the grammar entry, not the derived
    semanticTypes restatement.
    """
    grammar_entry = index["grammar_by_tag"].get(element_name)
    if grammar_entry is None:
        return {}
    return grammar_field_bodies(grammar_entry, element_name)


def directory_of(path):
    """The directory holding one resolved configuration file."""
    return os.path.dirname(os.path.abspath(path)) or os.curdir
