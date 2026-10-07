#!/usr/bin/env python3
"""Census of the git config keys git-absorb reads.

Input : the source tree the package builds (src + patches), parsed with
        tree-sitter-rust; and its Documentation/git-absorb.adoc, converted to
        DocBook by asciidoc (the format's own reference parser).
Output: extracted.json in the shared sidecar schema (lib/git-tool-settings):
        facts only. A key the man page does not describe has no
        `description`, and a const nothing reads is a dead key with no
        reason; the rows in annotations.json supply both, in Nix
        (lib/git-tool-settings/rules.nix).
Exit  : non-zero when any guard trips:
  F1  a key that does not reduce to a string literal
  F2  a read method outside METHOD_TYPES
  F6  a config handle or git2::Config method used outside the read shape
  F7  a production "config" string literal (git-absorb runs no `git config`)
  F8  the man page documents a key the source never reads
  F9  a key-shaped string literal no read or dead key accounts for
  F10 a key or default passed through a parameter with no production caller
  F11 a test cfg the test filter cannot classify
  F12 a read whose match arms are not `Ok(v) [if v > N] => v [as T], _ => D`,
      or a read combined with a CLI field by anything but `config.f || read`
  F13 one key read with different types, defaults, minimums or CLI flags, or
      an identifier that names consts in several other files
  F15 fewer settings than the floor

Every Rust fact is a typed tree node (lib/git-tool-settings/rust_tree.py).
The man page arrives as DocBook XML and its config examples as INI parsed by
configparser; the one regular expression left rewrites a prose lead-in
sentence (see LEAD_IN).
"""

import argparse
import configparser
import json
import re
import subprocess
import tomllib
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

import rust_tree as rt
from census import Census, sites

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--src", type=Path, required=True)
args = parser.parse_args()

census = Census("absorb")
fail = census.fail
tree = rt.RustTree(args.src)
text = rt.text

METHOD_TYPES = {"get_bool": "bool", "get_i32": "int", "get_i64": "int",
                "get_str": "string", "get_string": "string", "get_path": "path"}
# git2::Config's read and write surface; any call outside the read shape is F6.
CONFIG_METHODS = set(METHOD_TYPES) | {
    "get_bytes", "get_entry", "entries", "multivar", "set_bool", "set_i32", "set_i64", "set_str",
    "set_multivar", "remove_multivar", "open_level", "open_global", "add_file", "snapshot"}
# libgit2 reads these behind `repo.signature()`; the source never names them.
SIGNATURE_KEYS = ["user.email", "user.name"]
MIN_SETTINGS = 7
MAX_DEPTH = 3

for f, attr in tree.unclassified_test_attributes:
    fail("F11", f"unrecognized test cfg {text(attr)!r} at {f}:{rt.line(attr)}")


def fn_name(fn):
    return text(fn.child_by_field_name("name")) if fn is not None else None


def enclosing_fn(node):
    return rt.enclosing(node, "function_item")


def where(f, node):
    return f"{f}:{rt.line(node)}"


file_of = {}
for f, node in tree.nodes("function_item", "call_expression", "match_expression"):
    file_of[node.id] = f

# ── Consts, resolved the way Rust does: this file's own first ─────────
consts = defaultdict(list)
for f, c in tree.nodes("const_item"):
    consts[text(c.child_by_field_name("name"))].append((f, c))


def const_node(ident, f):
    """The const `ident` names from file `f`: its own, else the one other
    file's. Several other files' is ambiguous and fails (F13)."""
    candidates = consts.get(ident, [])
    local = [c for cf, c in candidates if cf == f]
    if local:
        return local[0]
    if len(candidates) > 1:
        fail("F13", f"{ident} at {f} names consts in {sorted(cf for cf, _ in candidates)}")
    return candidates[0][1] if len(candidates) == 1 else None


# ── Calls to each function, for parameter resolution ──────────────────
calls_to = defaultdict(list)
for f, call in tree.nodes("call_expression"):
    calls_to[rt.callee_name(call)].append((f, call))


def params(fn):
    return [rt.parameter_name(p) for p in fn.child_by_field_name("parameters").named_children if p.type == "parameter"]


def resolve(expr, f, fn, chain=(), depth=0):
    """Reduce an expression to literal values, one per production call path:
    [(value, chain)], where `chain` lists the calls that bound parameters,
    innermost first. None when it does not reduce."""
    node = rt.unwrap(expr)
    ok, value = rt.literal_value(node)
    if ok:
        return [(value, chain)]
    if node is None or node.type != "identifier":
        return None
    ident = text(node)
    names = params(fn) if fn is not None else []
    if ident in names:
        if depth >= MAX_DEPTH:
            return None
        callers = calls_to.get(fn_name(fn), [])
        if not callers:
            fail("F10", f"{fn_name(fn)}({ident}) has no production caller")
            return []
        out = []
        for cf, call in callers:
            call_args = rt.call_args(call)
            if len(call_args) != len(names):
                return None
            sub = resolve(call_args[names.index(ident)], cf, enclosing_fn(call), chain + (call,), depth + 1)
            if sub is None:
                return None
            out += sub
        return out
    const = const_node(ident, f)
    if const is not None:
        ok, value = rt.literal_value(const.child_by_field_name("value"))
        return [(value, chain)] if ok else None
    return None


def consistent(a, b):
    """Two parameter chains describe one call path when one extends the
    other (a literal needs no binding; a parameter binds the caller)."""
    shorter, longer = sorted((a, b), key=len)
    return longer[:len(shorter)] == shorter


# ── The read shape ────────────────────────────────────────────────────
def read_of(match):
    """(receiver producer call, method, key expr) when `match` matches on
    `X.config().and_then(|p| p.M(K))`, else None."""
    scrutinee = rt.unwrap(match.child_by_field_name("value"))
    outer = rt.method_call(scrutinee) if scrutinee is not None else None
    if not outer or outer[1] != "and_then" or len(rt.call_args(scrutinee)) != 1:
        return None
    producer = rt.unwrap(outer[0])
    produced = rt.method_call(producer) if producer is not None else None
    closure = rt.call_args(scrutinee)[0]
    if not produced or produced[1] != "config" or rt.call_args(producer) or closure.type != "closure_expression":
        return None
    closure_params = closure.child_by_field_name("parameters").named_children
    body = rt.unwrap(closure.child_by_field_name("body"))
    inner = rt.method_call(body) if body is not None else None
    if len(closure_params) != 1 or not inner or rt.unwrap(inner[0]).type != "identifier" \
            or text(rt.unwrap(inner[0])) != text(closure_params[0]) or len(rt.call_args(body)) != 1:
        return None
    return producer, body, inner[1], rt.call_args(body)[0]


def ok_arm_shape(arm):
    """minimum (or None) for `Ok(v) [if v > N | v >= N] => v [as T]`;
    False for anything else."""
    pattern = arm.child_by_field_name("pattern")
    inner = pattern.named_children[0] if pattern is not None and pattern.named_children else None
    if inner is None or inner.type != "tuple_struct_pattern" or text(inner.child_by_field_name("type")) != "Ok":
        return False
    bound = [c for c in inner.named_children if c.id != inner.child_by_field_name("type").id]
    if len(bound) != 1 or bound[0].type != "identifier":
        return False
    name = text(bound[0])
    value = rt.unwrap(arm.child_by_field_name("value"))
    if value is not None and value.type == "type_cast_expression":
        value = value.child_by_field_name("value")
    if value is None or value.type != "identifier" or text(value) != name:
        return False
    condition = pattern.child_by_field_name("condition")
    if condition is None:
        return None
    if condition.type != "binary_expression":
        return False
    left, right = condition.child_by_field_name("left"), condition.child_by_field_name("right")
    operator = text(condition.child_by_field_name("operator"))
    ok, bound_value = rt.literal_value(right)
    if left.type != "identifier" or text(left) != name or operator not in (">", ">=") or not ok:
        return False
    return bound_value + (1 if operator == ">" else 0)


def is_wildcard(arm):
    pattern = arm.child_by_field_name("pattern")
    return pattern is not None and text(pattern) == "_"


# ── F6: nothing touches config outside the read shape ─────────────────
reads = [(f, m, shape) for f, m in tree.nodes("match_expression") if (shape := read_of(m))]
allowed = {id_ for _, _, (producer, body, _, _) in reads for id_ in (producer.id, body.id)}
for f, call in tree.nodes("call_expression"):
    as_method = rt.method_call(call)
    as_path = rt.path_call(call)
    raw = (as_method and (as_method[1] in CONFIG_METHODS or (as_method[1] == "config" and not rt.call_args(call)))) \
        or (as_path and as_path[0] in ("Config", "git2::Config"))
    if raw and call.id not in allowed:
        fail("F6", f"{text(call).splitlines()[0]!r} at {where(f, call)} is outside the recognised read shape")

# ── F7: git-absorb shells out to git, but never to `git config` ───────
for f, lit in tree.nodes("string_literal", "raw_string_literal"):
    if rt.string_value(lit) == "config":
        fail("F7", f"\"config\" literal at {where(f, lit)}: a subprocess git config the census does not model")


# ── CLI linkage: `field: config.field || <read>` in a struct literal ──
def clap_fields():
    """name → (doc, has long flag) for fields of a `#[derive(..Parser)]` struct."""
    out = {}
    for _, item in tree.nodes("struct_item"):
        derives = [leaf for a in rt.leading_attributes(item) if rt.attribute_parts(a)[0] == "derive"
                   for leaf in rt.token_leaves(rt.attribute_parts(a)[1]) if leaf.type == "identifier"]
        if not any(text(d) == "Parser" for d in derives):
            continue
        for field in item.child_by_field_name("body").named_children:
            if field.type != "field_declaration":
                continue
            long_flag = any(leaf.type == "identifier" and text(leaf) == "long"
                            for a in rt.leading_attributes(field) if rt.attribute_parts(a)[1] is not None
                            for leaf in rt.token_leaves(rt.attribute_parts(a)[1]))
            out[text(field.child_by_field_name("name"))] = (rt.doc_comment(field), long_flag)
    return out


clap = clap_fields()


def flag(field):
    return "--" + field.replace("_", "-")


def or_fields():
    """(struct field, left operand, right operand) of every `f: a || b`."""
    for f, init in tree.nodes("field_initializer"):
        value = init.child_by_field_name("value")
        if value is not None and value.type == "binary_expression":
            yield f, init, value


def also_set_by(field):
    return sorted(flag(text(v.child_by_field_name("right"))) for _, init, v in or_fields()
                  if text(init.child_by_field_name("field")) == field and text(v.child_by_field_name("operator")) == "||"
                  and text(v.child_by_field_name("left")) == field and text(v.child_by_field_name("right")) in clap)


def cli_for(node):
    """The CLI flag ORed with the read at `node`, or None."""
    for f, init, value in or_fields():
        if not (value.start_byte <= node.start_byte and node.end_byte <= value.end_byte):
            continue
        field = text(init.child_by_field_name("field"))
        left = value.child_by_field_name("left")
        if text(value.child_by_field_name("operator")) != "||" or text(left) != f"config.{field}" or field not in clap:
            fail("F12", f"{text(init).splitlines()[0]!r} at {where(f, init)} does not OR a CLI field with this read")
            return None
        doc, long_flag = clap[field]
        return {"flag": flag(field) if long_flag else None, "doc": doc, "alsoSetBy": also_set_by(field)}
    return None


# ── Reads ─────────────────────────────────────────────────────────────
records = []
for f, match, (producer, body, method, key_expr) in reads:
    fn = enclosing_fn(match)
    if method not in METHOD_TYPES:
        fail("F2", f"read method {method} at {where(f, match)}")
        continue
    arms = [a for a in match.child_by_field_name("body").named_children if a.type == "match_arm"]
    ok_arms = [(a, ok_arm_shape(a)) for a in arms if not is_wildcard(a)]
    wild = [a for a in arms if is_wildcard(a)]
    if len(arms) != 2 or len(wild) != 1 or len(ok_arms) != 1 or ok_arms[0][1] is False:
        fail("F12", f"read at {where(f, match)} has arms {[text(a.child_by_field_name('pattern')) for a in arms]}")
        continue
    minimum = ok_arms[0][1]
    keys = resolve(key_expr, f, fn)
    if keys is None:
        fail("F1", f"key {text(key_expr)!r} at {where(f, match)}")
        continue
    defaults = resolve(wild[0].child_by_field_name("value"), f, fn)
    if defaults is None:
        fail("F12", f"default {text(wild[0].child_by_field_name('value'))!r} at {where(f, match)} does not reduce to a literal")
        continue
    for key, key_chain in keys:
        paired = [(d, c) for d, c in defaults if consistent(key_chain, c)]
        if not paired:
            fail("F12", f"{key} at {where(f, match)} has no default on its call path")
            continue
        for default, default_chain in paired:
            chain = max((key_chain, default_chain), key=len)
            outer = chain[-1] if chain else match
            outer_fn = enclosing_fn(outer)
            records.append({"key": key, "type": METHOD_TYPES[method], "default": default, "minimum": minimum,
                            "file": file_of.get(outer_fn.id, f) if outer_fn is not None else f,
                            "fn": fn_name(outer_fn), "access": "read", "handles": ["repository"],
                            "cli": cli_for(outer), "where": where(f, match)})

# ── Foreign: implicit libgit2 reads ───────────────────────────────────
foreign_records = [r for r in records if not census.owns(r["key"])]
records = [r for r in records if census.owns(r["key"])]
for f, call in tree.nodes("call_expression"):
    as_method = rt.method_call(call)
    if as_method and as_method[1] == "signature" and not rt.call_args(call):
        fn = enclosing_fn(call)
        for key in SIGNATURE_KEYS:
            foreign_records.append({"key": key, "file": f, "fn": fn_name(fn), "access": "read",
                                    "handles": ["repository"]})


# ── Documentation/git-absorb.adoc CONFIGURATION ───────────────────────
# Prose, not code: the man page says "edit your local or global `.gitconfig`
# and add the following section:" before an example; in an option's
# description that becomes "set `absorb.x = v`". asciidoc keeps the source's
# line breaks inside a paragraph, so the pattern takes any whitespace run
# between words (mutant K14 re-wraps the sentence mid-phrase).
LEAD_IN = re.compile(r"(,|\.)?\s*edit\s+your\s+local\s+or\s+global\s+`\.gitconfig`\s+and\s+add\s+the\s+following\s+section:$")


def inline_text(element):
    """A DocBook paragraph as plain text, `<literal>` spans in backticks."""
    parts = [element.text or ""]
    for child in element:
        inner = inline_text(child)
        parts.append(f"`{inner}`" if child.tag == "literal" else inner)
        parts.append(child.tail or "")
    # asciidoc typesets apostrophes; the option text keeps the source's.
    return " ".join("".join(parts).split()).replace("\u2019", "'")


def example_keys(block):
    """`absorb.<key>` → value for an INI example block, else {}."""
    ini = configparser.ConfigParser(inline_comment_prefixes=("#",))
    ini.optionxform = str
    try:
        ini.read_string("\n".join(line.strip() for line in block.splitlines()))
    except configparser.Error:
        return {}
    return {f"absorb.{k}": v for k, v in ini["absorb"].items()} if ini.has_section("absorb") else {}


def man_descriptions(adoc):
    xml = subprocess.run(["asciidoc", "-b", "docbook", "-d", "manpage", "-o", "-", str(adoc)],
                         check=True, capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    section = next((s for s in root.iter("refsect1") if (s.findtext("title") or "").strip() == "CONFIGURATION"), None)
    out = {}
    for sub in ([] if section is None else section.iter("refsect2")):
        # One running text per subsection: an example block rewrites the
        # sentence that leads into it, wherever the paragraph broke.
        running, keys = "", {}
        for element in sub:
            if element.tag == "simpara":
                running = f"{running} {inline_text(element)}".strip()
            elif element.tag == "literallayout":
                example = example_keys(element.text or "")
                if example:
                    keys.update(example)
                    setting = ", ".join(f"`{k} = {v}`" for k, v in example.items())
                    if LEAD_IN.search(running):
                        running = LEAD_IN.sub(lambda m: (". Set " if m.group(1) == "." else ", set ") + setting + ".", running)
                    elif running.endswith(":"):
                        running = running[:-1] + " " + setting + "."
                    else:
                        running = f"{running} {setting}".strip()
                elif running.endswith(":"):
                    # Sample output, not configuration: drop the sentence
                    # that introduces it.
                    head = running[:-1].rsplit(". ", 1)
                    running = head[0] + "." if len(head) == 2 else ""
        for key in keys:
            out[key] = running
    return out


docs = man_descriptions(args.src / "Documentation/git-absorb.adoc")

# ── Assemble ──────────────────────────────────────────────────────────
by_key = defaultdict(list)
for r in records:
    by_key[r["key"]].append(r)

settings = {}
for key, rs in sorted(by_key.items()):
    entry = {"reads": sites(rs, "read"), "writes": {}, "status": "current", "invalid": "default",
             "type": census.agree(key, "types", [r["type"] for r in rs], "F13")}
    entry["default"] = census.agree(key, "defaults", [r["default"] for r in rs], "F13")
    minimum = census.agree(key, "minimums", [r["minimum"] for r in rs], "F13")
    if minimum is not None:
        entry["minimum"] = minimum
    clis = [r["cli"] for r in rs if r["cli"]]
    if clis:
        entry["cli"] = census.agree(key, "CLI flags", clis, "F13")
    # A blank paragraph is no description: the needs rule must see the key
    # as having no description rather than accept "".
    if docs.get(key, "").strip():
        entry["description"] = docs[key]
    settings[key] = entry

foreign_by_key = defaultdict(list)
for r in foreign_records:
    foreign_by_key[r["key"]].append(r)
foreign = {}
for key, rs in sorted(foreign_by_key.items()):
    entry = {"reads": sites(rs, "read"), "writes": {}}
    typed = [r for r in rs if "type" in r]
    if typed:
        entry["type"] = census.agree(key, "types", [r["type"] for r in typed], "F13")
        entry["default"] = census.agree(key, "defaults", [r["default"] for r in typed], "F13")
    foreign[key] = entry

for key in sorted(set(docs) - set(settings)):
    fail("F8", f"Documentation/git-absorb.adoc documents {key}, which the source never reads")

# ── Dead keys: key-shaped consts no read resolves to ──────────────────
dead = {}
for ident, entries in consts.items():
    for f, c in entries:
        ok, value = rt.literal_value(c.child_by_field_name("value"))
        if ok and isinstance(value, str) and census.key_tokens(value) == [value] and value not in settings:
            dead[value] = {"const": ident, "file": f}

# ── F9: the literal net ───────────────────────────────────────────────
known = set(settings) | set(dead)
for f, lit in tree.nodes("string_literal", "raw_string_literal"):
    for token in census.key_tokens(rt.string_value(lit)):
        if token not in known:
            fail("F9", f"string literal at {where(f, lit)} names {token}, which no recognised read extracts")

if len(settings) < MIN_SETTINGS:
    fail("F15", f"only {len(settings)} settings extracted (floor {MIN_SETTINGS})")

for key, e in sorted(settings.items()):
    cli = (e.get("cli") or {}).get("flag") or "-"
    print(f"{key:34} {e['type']:5} default={json.dumps(e.get('default')):6} min={e.get('minimum', '-')!s:2} "
          f"cli={cli:24} {','.join(e['reads'])}")
print(f"\n{len(records)} key sites, {len(settings)} settings, {len(foreign)} foreign keys, {len(dead)} dead keys")

census.finish(args.out, {
    "deadKeys": dict(sorted(dead.items())),
    "foreign": foreign,
    "settings": settings,
    "source": {"version": tomllib.loads((args.src / "Cargo.toml").read_text())["package"]["version"]},
})
