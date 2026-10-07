#!/usr/bin/env python3
"""Census of the git config keys git-branchless reads and writes.

Input : the PATCHED source tree (the package's unpack + patch output), parsed
        with tree-sitter-rust.
Output: extracted.json, one record per key (see the sidecar at the bottom):
        facts only. A read with no type or doc comment has neither field, and
        a key-shaped const nothing reads is a dead key with no reason; the
        rows in annotations.json supply them, in Nix
        (lib/git-tool-settings/rules.nix).
Exit  : non-zero when any guard trips. Every guard names its code (F1..F15)
        so a failure says which call shape the resolver no longer
        understands. A new upstream key never disappears silently: either it
        lands in the output, or the build fails.

Every fact comes from walking the syntax tree (lib/git-tool-settings/
rust_tree.py): call shapes, receivers, keys, defaults, types, enum variants,
doc comments and the builtin revset table are all typed nodes. Two regular
expressions remain, and both run over already-decoded prose, never over
code: the key-token net over string literal VALUES (census.py, F9) and the
`(deprecated)` marker inside doc comment text (status, below).
"""

import argparse
import json
import re
import tomllib
from collections import defaultdict
from pathlib import Path

import rust_tree as rt
from census import Census, sites

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--src", type=Path, required=True)
args = parser.parse_args()

census = Census("branchless")
fail = census.fail
tree = rt.RustTree(args.src)
text = rt.text

# ── Fixed knowledge about the API, itself guarded (F5) ─────────────────
API_FILE = "git-branchless-lib/src/git/config.rs"
EXPECTED_TRAIT_METHODS = {
    "into_config", "list", "get", "get_or", "get_or_else",  # ConfigRead
    "set", "remove", "set_multivar", "remove_multivar",  # ConfigWrite
}
EXPECTED_VALUE_TYPES = {"String", "bool", "i32", "PathBuf"}
# Producers of a config handle, and which config chain each one reads. A
# function whose return type names Config is added as a producer at run time
# and inherits the provenance of the producer it calls, when it has one.
BASE_PRODUCERS = {
    "get_readonly_config": "repository",
    "open_default": "global",
    "open": "file",
    "into_config": None,  # unwraps whatever handle it is called on
}
CONFIG_TYPES = {"Config", "ConfigRead"}
# The only places allowed to touch git2's config directly (F6).
RAW_ALLOW = {("git-branchless-lib/src/git/repo.rs", "get_readonly_config"),
             (API_FILE, None)}
# Shape floor: the census of the pinned release is far above these numbers.
# Falling under one means the scan stopped seeing the config API at all.
MIN_SETTINGS = 20
MIN_REVSET_FUNCTIONS = 20

# method → argument count: the only recognised ways to touch a config handle.
READ_ARITY = {"get": 1, "get_or": 2, "get_or_else": 2, "list": 1}
WRITE_ARITY = {"set": 2, "remove": 1, "set_multivar": 3, "remove_multivar": 2}
ARITY = {**READ_ARITY, **WRITE_ARITY}
RUST_TYPES = {"bool": "bool", "i32": "int", "String": "string", "PathBuf": "path",
              "path": "path"}

# ── F11: a test cfg the tree walk cannot classify ─────────────────────
for f, attr in tree.unclassified_test_attributes:
    fail("F11", f"unrecognized test cfg {text(attr)!r} at {f}:{rt.line(attr)}")


def fn_name(fn):
    return text(fn.child_by_field_name("name")) if fn is not None else None


def enclosing_fn(node):
    return rt.enclosing(node, "function_item")


def is_ident(node, name):
    node = rt.unwrap(node)
    return node is not None and node.type == "identifier" and text(node) == name


functions = defaultdict(list)
for f, fn in tree.nodes("function_item"):
    functions[fn_name(fn)].append((f, fn))

# ── Constants: string, bool and integer literals only ─────────────────
consts = defaultdict(list)
for f, c in tree.nodes("const_item"):
    ok, value = rt.literal_value(c.child_by_field_name("value"))
    if ok:
        consts[text(c.child_by_field_name("name"))].append((value, f, c))


def const_value(ident):
    """(ok, value) when `ident` names exactly one literal const."""
    values = consts.get(ident, [])
    return (True, values[0][0]) if len(values) == 1 else (False, None)


# ── F5: API drift guard ────────────────────────────────────────────────
trait_methods, value_types = set(), set()
for f, trait in tree.nodes("trait_item"):
    if f == API_FILE and text(trait.child_by_field_name("name")) in ("ConfigRead", "ConfigWrite"):
        trait_methods |= {text(m.child_by_field_name("name")) for m in trait.child_by_field_name("body").named_children
                          if m.type in ("function_signature_item", "function_item")}
for f, impl in tree.nodes("impl_item"):
    trait = impl.child_by_field_name("trait")
    if f == API_FILE and trait is not None and trait.type == "generic_type" \
            and text(trait.child_by_field_name("type")) == "GetConfigValue":
        value_types |= {text(t) for t in trait.child_by_field_name("type_arguments").named_children}
if trait_methods != EXPECTED_TRAIT_METHODS:
    fail("F5", f"ConfigRead/ConfigWrite methods changed: {sorted(trait_methods ^ EXPECTED_TRAIT_METHODS)}")
if value_types != EXPECTED_VALUE_TYPES:
    fail("F5", f"GetConfigValue impl types changed: {sorted(value_types ^ EXPECTED_VALUE_TYPES)}")


# ── Handle producers ──────────────────────────────────────────────────
def base_producer(call):
    """The BASE_PRODUCERS entry a call invokes, in the shape that API has:
    `x.get_readonly_config()`, `x.into_config()`, `Config::open(..)` or
    `Config::open_default()`."""
    as_method = rt.method_call(call)
    if as_method and as_method[1] in ("get_readonly_config", "into_config"):
        return as_method[1]
    as_path = rt.path_call(call)
    if as_path and as_path[0] == "Config" and as_path[1] in ("open", "open_default"):
        return as_path[1]
    return None


def returns_config(fn):
    return bool(rt.type_identifiers(fn.child_by_field_name("return_type")) & CONFIG_TYPES)


# A function returning a handle reads the chain of the base producer it
# calls, when it calls exactly one kind (create_isolated_config opens one
# file); otherwise its provenance is just its name.
producers = dict(BASE_PRODUCERS)
for f, fn in tree.nodes("function_item"):
    name = fn_name(fn)
    if name in producers or not returns_config(fn):
        continue
    kinds = {BASE_PRODUCERS[p] for c in rt.descendants(fn, {"call_expression"}) if (p := base_producer(c))} - {None}
    producers[name] = kinds.pop() if len(kinds) == 1 else f"via {name}"


def producer_of(call):
    """The producer a call invokes: a base producer in its API shape, or a
    derived one called by name in any form."""
    base = base_producer(call)
    if base:
        return base
    name = rt.callee_name(call)
    return name if name in producers and name not in BASE_PRODUCERS else None


def producer_calls(node):
    """Producer calls inside `node`, ordered by where their name token sits
    (for `a.b()` the `b`, for `f(x)` the `f`)."""
    found = []
    for call in rt.descendants(node, {"call_expression"}):
        name = producer_of(call)
        if name:
            function = call.child_by_field_name("function")
            anchor = function.child_by_field_name("field") if function.type == "field_expression" else function
            found.append((anchor.start_byte, name))
    return [name for _, name in sorted(found)]


# ── F6: raw git2 config access outside the allowlist ──────────────────
def raw_config_sites():
    for f, call in tree.nodes("call_expression"):
        as_method = rt.method_call(call)
        if as_method and as_method[1] == "config" and not rt.call_args(call):
            yield f, call
    for f, node in tree.nodes("scoped_identifier", "scoped_type_identifier"):
        path, name = node.child_by_field_name("path"), node.child_by_field_name("name")
        if path is not None and text(path) == "git2" and name is not None and text(name) == "Config":
            yield f, node


for f, node in raw_config_sites():
    name = fn_name(enclosing_fn(node))
    if (f, name) not in RAW_ALLOW and (f, None) not in RAW_ALLOW:
        fail("F6", f"raw git2 config access {text(node)!r} at {f}:{rt.line(node)} in fn {name}")


# ── Receiver classification and handle provenance ─────────────────────
def own_params(fn):
    return [p for p in fn.child_by_field_name("parameters").named_children if p.type == "parameter"]


calls_to = defaultdict(list)
for f, call in tree.nodes("call_expression"):
    calls_to[rt.callee_name(call)].append(call)


def lets_before(fn, ident, before):
    return [l for l in rt.descendants(fn, {"let_declaration"})
            if rt.pattern_name(l.child_by_field_name("pattern")) == ident and l.start_byte < before]


def handle_of(expr, fn, before, depth=0):
    """The config chains an expression's handle reads, or None if it is not a
    config handle. `repository` is the repository's full chain, `global` the
    global/XDG/system chain without the repository, `file` one isolated file.
    A handle passed in as a parameter takes the chains of every caller's
    argument; `parameter` remains only when no caller resolves."""
    if expr is None:
        return None
    found = producer_calls(expr)
    kinds = [producers[name] for name in found if producers[name]]
    if kinds:
        return {kinds[-1]}
    inner = rt.unwrap(expr)
    as_method = rt.method_call(inner) if inner is not None else None
    if as_method and as_method[1] == "into_config" and depth <= 4:
        return handle_of(as_method[0], fn, before, depth + 1)
    if found:
        return {"unknown"}
    if inner is None or inner.type != "identifier" or depth > 4 or fn is None:
        return None
    ident = text(inner)
    params = own_params(fn)
    for index, p in enumerate(params):
        if rt.parameter_name(p) != ident:
            continue
        if not rt.type_identifiers(p.child_by_field_name("type")) & CONFIG_TYPES:
            return None
        chains = set()
        for call in calls_to[fn_name(fn)]:
            call_args = rt.call_args(call)
            caller = enclosing_fn(call)
            if len(call_args) == len(params) and caller is not None:
                chains |= handle_of(call_args[index], caller, call.start_byte, depth + 1) or set()
        return chains or {"parameter"}
    lets = lets_before(fn, ident, before)
    if lets:
        last = max(lets, key=lambda l: l.start_byte)
        return handle_of(last.child_by_field_name("value"), fn, last.start_byte, depth + 1)
    return None


# ── Key resolution ─────────────────────────────────────────────────────
def format_key(node):
    """`format!("prefix.{x}", ..)` → `prefix.<name>`, else None. The format
    string is the macro token tree's first argument; every placeholder is one
    dynamic segment, whatever the argument expression looks like."""
    parts = rt.macro_parts(node)
    if not parts or parts[0] != "format" or parts[1] is None:
        return None
    groups = rt.split_token_tree(parts[1])
    if not groups or len(groups[0]) != 1 or groups[0][0].type not in rt.STRING_KINDS:
        return None
    return "".join("<name>" if piece is None else piece
                   for piece in rt.format_placeholders(rt.string_value(groups[0][0])))


def arm_key(arm):
    """(key, variant pattern) for an `Enum::Variant => "key"` arm, else None."""
    value = arm.child_by_field_name("value")
    if value is None or value.type not in rt.STRING_KINDS:
        return None
    pattern = arm.child_by_field_name("pattern")
    variant = pattern.named_children[0] if pattern is not None and pattern.named_child_count == 1 else pattern
    return rt.string_value(value), variant


enum_items = defaultdict(list)
for f, e in tree.nodes("enum_item"):
    enum_items[text(e.child_by_field_name("name"))].append(e)


def enum_variants(name):
    for e in enum_items.get(name, []):
        for v in e.child_by_field_name("body").named_children:
            if v.type == "enum_variant":
                yield v


def variant_doc(variant):
    """Doc comment of the variant an `Enum::Variant` pattern names."""
    if variant is None or variant.type != "scoped_identifier":
        return None
    path = variant.child_by_field_name("path")
    enum = text(path).split("::")[-1] if path is not None else None
    name = text(variant.child_by_field_name("name"))
    match = [v for v in enum_variants(enum) if text(v.child_by_field_name("name")) == name]
    return rt.doc_comment(match[0]) if match else None


def resolve_key(expr, fn, before):
    """Return list of (key, provenance, extra) or None when unresolvable (F2)."""
    node = rt.unwrap(expr)
    if node is None:
        return None
    if node.type in rt.STRING_KINDS:
        return [(rt.string_value(node), "literal", {})]
    if node.type == "macro_invocation":
        pattern = format_key(node)
        return [(pattern, "format!", {})] if pattern else None
    as_method = rt.method_call(node)
    if as_method and as_method[0].type == "identifier" and as_method[2] is None and not rt.call_args(node):
        out = []  # a method returning a key: enumerate its string match arms
        for f, target in functions.get(as_method[1], []):
            keyed = [(arm, arm_key(arm)) for arm in rt.descendants(target, {"match_arm"})]
            odd = [text(arm.child_by_field_name("value")) for arm, key in keyed if key is None]
            if odd:
                fail("F2", f"key-returning fn {as_method[1]} at {f}:{rt.line(target)} has non-literal match arms {odd!r}")
                return []
            for _, (key, variant) in keyed:
                out.append((key, f"match-arm {text(variant)}", {"doc": variant_doc(variant)}))
        return out or None
    if node.type == "identifier":
        ident = text(node)
        if fn is not None:
            lets = lets_before(fn, ident, before)
            if lets:
                return resolve_key(max(lets, key=lambda l: l.start_byte).child_by_field_name("value"), fn, before)
        ok, value = const_value(ident)
        if ok and isinstance(value, str):
            return [(value, f"const {ident}", {})]
    return None


# ── Type and default inference ────────────────────────────────────────
def default_value(expr):
    """(ok, value) for a default expression: a literal, or a const that holds
    one, optionally converted to an owned string. Anything else is F12."""
    node = rt.unwrap(expr)
    if node is None:
        return False, None
    if rt.path_call(node) == ("String", "from") and len(rt.call_args(node)) == 1:
        return default_value(rt.call_args(node)[0])
    as_method = rt.method_call(node)
    if as_method and as_method[1] in ("to_string", "to_owned", "into") and not rt.call_args(node):
        return default_value(as_method[0])
    ok, value = rt.literal_value(node)
    if ok:
        return ok, value
    if node.type == "identifier":
        return const_value(text(node))
    return False, None


def closure_result(closure):
    """The expression a `|| expr` or `|| { expr }` closure returns, when its
    body is exactly that one expression; the node itself otherwise."""
    if closure is None or closure.type != "closure_expression":
        return closure
    if closure.child_by_field_name("parameters").named_child_count:
        return None
    body = closure.child_by_field_name("body")
    if body is not None and body.type == "block":
        inner = [c for c in body.named_children if c.type not in rt.ATTRIBUTE_SIBLINGS]
        return inner[0] if len(inner) == 1 and not inner[0].type.endswith(("_statement", "_declaration")) else None
    return body


def value_type(value):
    return "bool" if isinstance(value, bool) else "int" if isinstance(value, int) else "string"


def annotated_let(call, fn):
    """The outermost typed `let` whose value holds `call`: (its type with any
    `Option<>` removed, the bound name, the let node)."""
    for l in rt.descendants(fn, {"let_declaration"}):
        type_node = l.child_by_field_name("type")
        if type_node is not None and l.start_byte <= call.start_byte and call.end_byte <= l.end_byte:
            return text(rt.option_inner(type_node)), rt.pattern_name(l.child_by_field_name("pattern")), l
    return None, None, None


def kebab(name):
    """clap's kebab-case spelling of a variant identifier."""
    return "".join(("-" if i and ch.isupper() else "") + ch.lower() for i, ch in enumerate(name))


def is_value_enum(item):
    for attr in rt.leading_attributes(item):
        path, attr_args = rt.attribute_parts(attr)
        if path == "derive" and attr_args is not None and any(
                leaf.type == "identifier" and text(leaf) == "ValueEnum" for leaf in rt.token_leaves(attr_args)):
            return True
    return False


def enum_values(name):
    if not any(is_value_enum(e) for e in enum_items.get(name, [])):
        return None
    return [{"value": kebab(text(v.child_by_field_name("name"))), "description": rt.doc_comment(v)}
            for v in enum_variants(name)]


def none_default(fn, ident, after):
    """The value of the first `None => ..` arm, after `after`, of a match
    whose subject is `ident`."""
    for arm in rt.descendants(fn, {"match_arm"}):
        pattern = arm.child_by_field_name("pattern")
        match = rt.enclosing(arm, "match_expression")
        if arm.start_byte > after and pattern is not None and pattern.named_child_count == 1 \
                and is_ident(pattern.named_children[0], "None") and match is not None \
                and is_ident(match.child_by_field_name("value"), ident):
            return arm.child_by_field_name("value")
    return None


def is_unset(node):
    """`None`, `Ok(None)`, `return None` or `return Ok(None)`."""
    if node is not None and node.type == "return_expression":
        node = node.named_children[0] if node.named_child_count == 1 else None
    if node is not None and rt.path_call(node) == (None, "Ok") and len(rt.call_args(node)) == 1:
        node = rt.call_args(node)[0]
    return is_ident(node, "None")


def parsed_enum(fn, ident, after):
    for call in rt.descendants(fn, {"call_expression"}):
        as_path = rt.path_call(call)
        call_args = rt.call_args(call)
        if call.start_byte > after and as_path and as_path[1] == "from_str" and as_path[0] \
                and call_args and is_ident(call_args[0], ident):
            return as_path[0]
    return None


def enum_default(node, enum):
    if node is not None and node.type == "scoped_identifier":
        path = node.child_by_field_name("path")
        if path is not None and text(path) == enum:
            return kebab(text(node.child_by_field_name("name")))
    return None


# ── Walk call sites ────────────────────────────────────────────────────
records = []
for f, call in tree.nodes("call_expression"):
    as_method = rt.method_call(call)
    if f == API_FILE or not as_method or as_method[1] not in ARITY:
        continue
    recv, method, turbofish = as_method
    fn = enclosing_fn(call)
    handle = handle_of(recv, fn, call.start_byte)
    if handle is None:
        continue
    call_args = rt.call_args(call)
    if len(call_args) != ARITY[method] or (turbofish is not None and method != "get"):
        fail("F1", f"unrecognized call shape on a config handle: {text(call)!r} at {f}:{rt.line(call)}")
        continue
    if fn is None:
        continue
    keys = resolve_key(call_args[0], fn, call.start_byte)
    if keys is None:
        fail("F2", f"unresolvable key expression {text(call_args[0])!r} at {f}:{rt.line(call)}")
        continue
    for key, prov, extra in keys:
        rec = {"key": key, "access": "read" if method in READ_ARITY else "write",
               "method": method, "file": f, "at": call.start_byte, "line": rt.line(call), "fn": fn_name(fn),
               "handles": handle, "key_from": prov, "type": None, "default": None,
               "has_default": False, "values": None,
               "doc": extra.get("doc") or rt.doc_comment(fn)}
        if turbofish is not None:
            rec["type"] = text(turbofish.named_children[0])
        if method in ("get_or", "get_or_else"):
            given = call_args[1]
            ok, value = default_value(closure_result(given) if method == "get_or_else" else given)
            if ok:
                rec["type"], rec["default"], rec["has_default"] = value_type(value), value, True
            elif census.owns(key):
                fail("F12", f"default {text(given)!r} for {key} at {f}:{rec['line']} is neither a literal nor a literal const")
        if method == "list":
            rec["type"] = "String"  # (name, value) pairs of one family
        if method == "get":
            t, ident, let = annotated_let(call, fn)
            if t and not rec["type"]:
                rec["type"] = t
            if ident:
                enum = parsed_enum(fn, ident, let.start_byte)
                if enum:
                    rec["values"] = enum_values(enum)
                    rec["type"] = f"enum {enum}"
                nd = none_default(fn, ident, let.start_byte)
                if nd is not None and not is_unset(nd):
                    variant = enum_default(nd, enum) if enum else None
                    if variant:
                        rec["default"], rec["has_default"] = variant, True
                    else:
                        ok, value = default_value(nd)
                        if ok:
                            rec["default"], rec["has_default"] = value, True
                        elif census.owns(key):
                            fail("F12", f"None-arm default {text(nd)!r} for {key} at {f}:{rec['line']} "
                                        "is neither a literal, an enum variant nor a literal const")
        if method == "set":
            ok, value = rt.literal_value(rt.unwrap(call_args[1]))
            rec["type"] = value_type(value) if ok else None
        records.append(rec)

# ── F7: git subprocess `config` argv ───────────────────────────────────
# Any array with a literal "config" element is a git argv, wherever the
# element sits (`["-C", dir, "config", ..]` included), and every element
# must then be a literal.
for f, array in tree.nodes("array_expression"):
    elements = [c for c in array.named_children if c.type not in rt.ATTRIBUTE_SIBLINGS]
    values = [rt.string_value(e) for e in elements]
    if "config" not in values:
        continue
    fn = enclosing_fn(array)
    if None in values:
        fail("F7", f"non-literal git config argv at {f}:{rt.line(array)}: {text(array)!r}")
        continue
    argv = values[values.index("config") + 1:]
    for k in [a for a in argv if "." in a and not a.startswith("-")]:
        records.append({"key": k, "access": "read", "method": "git-subprocess", "file": f,
                        "at": array.start_byte, "line": rt.line(array), "fn": fn_name(fn),
                        "handles": {"git subprocess"}, "key_from": "argv-literal",
                        "type": argv[argv.index("--type") + 1] if "--type" in argv else "String",
                        "default": None, "has_default": False, "values": None,
                        "doc": rt.doc_comment(fn) if fn is not None else None})

# ── F10: every obtained handle must lead to an extracted key ──────────
fns_with_records = {(r["file"], r["fn"]) for r in records}


def config_callee(call):
    """Does the called function take a Config-typed parameter?"""
    return any(rt.type_identifiers(p.child_by_field_name("type")) & CONFIG_TYPES
               for _, g in functions.get(rt.callee_name(call), [])
               for p in rt.descendants(g, {"parameter"}))


def mentions(node, ident):
    return node is not None and any(text(i) == ident for i in rt.descendants(node, {"identifier"}))


for f, call in tree.nodes("call_expression"):
    if f == API_FILE or not base_producer(call):
        continue
    fn = enclosing_fn(call)
    name = fn_name(fn)
    if (f, name) in RAW_ALLOW or (f, name) in fns_with_records:
        continue
    # Otherwise the handle must be handed to a callee whose parameter is
    # Config-typed (e.g. create_isolated_config, install_alias); that callee
    # is then covered by receiver resolution.
    holder = [l for l in rt.descendants(fn, {"let_declaration"})
              if l.start_byte <= call.start_byte and call.end_byte <= l.end_byte] if fn else []
    token = rt.pattern_name(holder[0].child_by_field_name("pattern")) if holder else None
    handed = any(config_callee(c) and (c.start_byte <= call.start_byte and call.end_byte <= c.end_byte
                                       or (token and mentions(c.child_by_field_name("arguments"), token)))
                 for c in (rt.descendants(fn, {"call_expression"}) if fn else []))
    if not handed:
        fail("F10", f"config handle {text(call)!r} obtained at {f}:{rt.line(call)} in fn {name} but no key extracted there")
for f, field in tree.nodes("field_declaration"):
    type_node = field.child_by_field_name("type")
    if f != API_FILE and rt.type_identifiers(type_node) & CONFIG_TYPES:
        fail("F10", f"struct field {text(field.child_by_field_name('name'))}: {text(type_node)} at {f}:{rt.line(field)} "
                    "stores a config handle; extend receiver resolution")
for f, call in tree.nodes("call_expression"):
    as_path = rt.path_call(call)
    if f == API_FILE or not as_path:
        continue
    path, name = as_path
    constructor = path == "Config" and name in ("open", "open_default", "from")
    if (path in ("ConfigRead", "ConfigWrite", "Config") and not constructor) or (name == "get_from_config" and path):
        fail("F1", f"UFCS config call {text(call)[:60]!r} at {f}:{rt.line(call)}")

# ── Normalization ─────────────────────────────────────────────────────
enum_doc = {name: rt.doc_comment(e) for name, items in enum_items.items() for e in items if is_value_enum(e)}
for r in records:
    r["key_raw"] = r["key"]
    # A list glob is the same `<name>` family a format! key already is.
    if r["method"] == "list" and r["key"].endswith(".*"):
        r["key"] = r["key"][:-2] + ".<name>"
    # Rustdoc is only trusted on accessor functions (`get_*`) or when it came
    # from an enum variant; otherwise it describes the caller, not the key.
    if r["doc"] and "match-arm" not in r["key_from"] and not (r["fn"] or "").startswith("get_"):
        r["doc"] = None
    if r["type"] and r["type"].startswith("enum "):
        r["doc"] = enum_doc.get(r["type"][5:])
all_docs = " ".join(r["doc"] or "" for r in records)

# ── Dead keys: key-shaped consts nothing reads ────────────────────────
read_raw = {r["key_raw"] for r in records}
dead = {}
for ident, entries in consts.items():
    for value, f, c in entries:
        if isinstance(value, str) and census.key_tokens(value) == [value] and value not in read_raw:
            dead[value] = {"const": ident, "file": f}

# ── Aggregate the sites into one record per key ───────────────────────
by_key = defaultdict(list)
for r in records:
    by_key[r["key"]].append(r)

settings, foreign = {}, {}
for key, rs in sorted(by_key.items()):
    entry = {access + "s": sites(rs, access) for access in ("read", "write")}
    if not census.owns(key):
        foreign[key] = entry
        continue
    rd = [r for r in rs if r["access"] == "read"] or rs
    raw_type = census.agree(key, "types", [r["type"] for r in rd if r["type"]], "F13")
    if raw_type and raw_type.startswith("enum "):
        entry["type"] = "enum"
        entry["values"] = census.agree(key, "enum values", [r["values"] for r in rd if r["values"]], "F13")
    elif raw_type:
        entry["type"] = RUST_TYPES.get(raw_type, raw_type)
    defaults = [r["default"] for r in rd if r["has_default"]]
    if defaults:
        entry["default"] = census.agree(key, "defaults", defaults, "F13")
    docs = sorted({r["doc"] for r in rd if r["doc"]})
    if docs:
        entry["description"] = docs[0]
    # Prose, not code: upstream marks a legacy key by writing
    # "(deprecated) <key>" in its accessor's doc comment. The lookahead
    # keeps "(deprecated) branchless.x.yz" from marking branchless.x.y, which
    # a plain prefix match would (mutant N8).
    legacy = re.search(r"\(deprecated\)\s*" + re.escape(key) + r"(?![\w.])", all_docs)
    entry["status"] = "legacy" if legacy else "current"
    settings[key] = entry


# ── F9: every key named in a production string literal is accounted for
def normalized(token):
    """A literal's key token with each dynamic segment (a format
    placeholder, a list glob, a `<name>`) spelled `<name>`."""
    try:
        pieces = rt.format_placeholders(token)
    except ValueError:
        return token
    joined, out, i = "".join("<name>" if p is None else p for p in pieces), [], 0
    while i < len(joined):
        if joined[i] == "*":
            out.append("<name>")
            i += 1
        elif joined[i] == "<" and ">" in joined[i:]:
            out.append("<name>")
            i = joined.index(">", i) + 1
        else:
            out.append(joined[i])
            i += 1
    return "".join(out)


family_prefixes = [k[: -len("<name>")] for k in by_key if k.endswith("<name>")]
known = set(by_key) | read_raw | set(dead)
for f, lit in tree.nodes("string_literal", "raw_string_literal"):
    for token in census.key_tokens(rt.string_value(lit)):
        if normalized(token) in known or token in known \
                or any(token.startswith(p) and len(token) > len(p) for p in family_prefixes):
            continue
        fail("F9", f"string literal at {f}:{rt.line(lit)} names {token}, which no recognised read or write extracts")


# ── F14: builtin revset functions, and that they shadow aliases ───────
def functions_tables():
    """Macro token trees declaring `static ref FUNCTIONS` (lazy_static)."""
    for _, macro in tree.nodes("macro_invocation"):
        parts = rt.macro_parts(macro)
        if not parts or parts[1] is None:
            continue
        leaves = list(rt.token_leaves(parts[1]))
        if any(a.type == "static" and text(b) == "ref" and text(c) == "FUNCTIONS"
               for a, b, c in zip(leaves, leaves[1:], leaves[2:])):
            yield parts[1]


def table_entries(token_tree):
    """Every `("name", ..)` token tree in the table: the name when the entry
    is exactly `("name", &function)`, None for any other shape."""
    for node in rt.descendants(token_tree, {"token_tree"}):
        inner = node.children[1:-1]
        if node.children[0].type != "(" or not inner or inner[0].type not in rt.STRING_KINDS:
            continue
        exact = [c.type for c in inner] == [inner[0].type, ",", "&", "identifier"]
        yield rt.string_value(inner[0]) if exact else None


tables = list(functions_tables())
entries = [name for t in tables for name in table_entries(t)]
revset_functions = sorted({name for name in entries if name is not None})
if len(tables) != 1:
    fail("F14", f"expected one `static ref FUNCTIONS` table, found {len(tables)}")
elif None in entries:
    fail("F14", f"FUNCTIONS has {len(entries)} entries but only {len(entries) - entries.count(None)} "
                "have the (\"name\", &fn) shape")
lookups = [(f, call) for f, call in tree.nodes("call_expression")
           if (m := rt.method_call(call)) and m[1] == "get" and is_ident(m[0], "FUNCTIONS")]
for r in records:
    if r["key"] != "branchless.revsets.alias.<name>" or r["access"] != "read":
        continue
    if not any(f == r["file"] and c.start_byte < r["at"] and fn_name(enclosing_fn(c)) == r["fn"] for f, c in lookups):
        fail("F14", f"{r['file']}#{r['fn']} no longer consults FUNCTIONS before branchless.revsets.alias.*; "
                    "the builtin-name rule in lib/git-tool-settings/default.nix may be wrong")

# ── F15: shape floor ──────────────────────────────────────────────────
current = [k for k, e in settings.items() if e["reads"] and e["status"] == "current"]
if len(current) < MIN_SETTINGS:
    fail("F15", f"only {len(current)} current settings extracted (floor {MIN_SETTINGS})")
if len(revset_functions) < MIN_REVSET_FUNCTIONS:
    fail("F15", f"only {len(revset_functions)} builtin revset functions extracted (floor {MIN_REVSET_FUNCTIONS})")

for key, e in sorted(settings.items()):
    print(f"{key:52} {e.get('type', '-')!s:7} {e['status']:7} default={json.dumps(e.get('default'))[:40]:42} "
          f"read via {','.join(sorted(set().union(*e['reads'].values())))}")
print(f"\n{len(records)} key sites, {len(settings)} settings, {len(foreign)} foreign keys, "
      f"{len(revset_functions)} builtin revset functions")

census.finish(args.out, {
    "deadKeys": dict(sorted(dead.items())),
    "foreign": foreign,
    "revsetFunctions": revset_functions,
    "settings": settings,
    "source": {"version": tomllib.loads((args.src / "git-branchless/Cargo.toml").read_text())["package"]["version"]},
})
