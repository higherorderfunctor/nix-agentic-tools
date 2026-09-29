#!/usr/bin/env python3
"""Census of the git config keys git-branchless reads and writes.

Input : the ast-grep JSON stream that rules/config.yml produces over the
        PATCHED source tree (the package's unpack + patch output), plus the
        hand annotations in annotations.json.
Output: extracted.json, one record per key (see `sidecar` at the bottom).
Exit  : non-zero when any guard trips. Every guard names its code (F1..F14)
        so a failure says which call shape the resolver no longer
        understands. A new upstream key never disappears silently: either it
        lands in the output, or the build fails.

Everything consumes AST node ranges and metavariable captures from ast-grep.
The only raw-text steps read `///` doc lines directly above an AST-located
item and scan the text of AST-located string literals for key names.
"""

import argparse
import json
import re
import sys
import tomllib
from collections import defaultdict
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--annotations", type=Path, required=True)
parser.add_argument("--matches", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--src", type=Path, required=True)
args = parser.parse_args()
SRC = args.src

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
# The only places allowed to touch git2's config directly (F6).
RAW_ALLOW = {("git-branchless-lib/src/git/repo.rs", "get_readonly_config"),
             (API_FILE, None)}
# Shape floor: the census of the pinned release is far above these numbers.
# Falling under one means the scan stopped seeing the config API at all.
MIN_SETTINGS = 20
MIN_REVSET_FUNCTIONS = 20

READ_SHAPES = {"shape-get": "get", "shape-get-turbofish": "get",
               "shape-get-or": "get_or", "shape-get-or-else": "get_or_else",
               "shape-list": "list"}
WRITE_SHAPES = {"shape-set": "set", "shape-remove": "remove",
                "shape-set-multivar": "set_multivar",
                "shape-remove-multivar": "remove_multivar"}
RUST_TYPES = {"bool": "bool", "i32": "int", "String": "string", "PathBuf": "path",
              "path": "path"}
KEY_TOKEN = re.compile(r"(?<![\w.-])branchless\.[A-Za-z{*][\w{}<>*.-]*")

failures = []


def fail(code, msg):
    failures.append(f"{code}: {msg}")


# ── Load matches ───────────────────────────────────────────────────────
by_rule = defaultdict(list)
for line in args.matches.read_text().splitlines():
    m = json.loads(line)
    m["mv"] = {k: v["text"] for k, v in m.get("metaVariables", {}).get("single", {}).items()}
    m["s"] = m["range"]["byteOffset"]["start"]
    m["e"] = m["range"]["byteOffset"]["end"]
    m["line"] = m["range"]["start"]["line"] + 1
    by_rule[m["ruleId"]].append(m)

test_spans = defaultdict(list)
for t in by_rule["test-item"]:
    test_spans[t["file"]].append((t["s"], t["e"]))


def is_test_path(f):
    return "/tests/" in f or f.endswith("testing.rs") or "/benches/" in f


def is_test(m):
    return is_test_path(m["file"]) or any(s <= m["s"] and m["e"] <= e for s, e in test_spans[m["file"]])


# Drop test code once, here, so no later step can forget to.
for rid in list(by_rule):
    if rid != "test-item":
        by_rule[rid] = [m for m in by_rule[rid] if not is_test(m)]

# ── F11: a test cfg the filter above cannot classify ──────────────────
for a in by_rule["cfg-test-attr"]:
    if re.sub(r"\s+", "", a["text"]) != "#[cfg(test)]":
        fail("F11", f"unrecognized test cfg {a['text']!r} at {a['file']}:{a['line']}")

src_lines = {}


def lines_of(f):
    if f not in src_lines:
        src_lines[f] = (SRC / f).read_text().splitlines()
    return src_lines[f]


def doc_above(f, line1):
    """Collect `///` lines directly above 1-based line, skipping #[attrs]."""
    ls, i, out = lines_of(f), line1 - 2, []
    while i >= 0:
        t = ls[i].strip()
        if t.startswith("///"):
            out.append(t[3:].strip())
        elif t.startswith("#[") or t == "":
            if t == "" and out:
                break
        else:
            break
        i -= 1
    return re.sub(r"\s+", " ", " ".join(reversed(out))).strip() or None


per_file = {}


def in_file(rule, f):
    if (rule, f) not in per_file:
        per_file[rule, f] = [c for c in by_rule[rule] if c["file"] == f]
    return per_file[rule, f]


def enclosing(rule, m):
    best = None
    for c in in_file(rule, m["file"]):
        if c["s"] <= m["s"] and m["e"] <= c["e"]:
            if best is None or c["e"] - c["s"] < best["e"] - best["s"]:
                best = c
    return best


def within(rule, fn):
    return [c for c in in_file(rule, fn["file"]) if fn["s"] <= c["s"] and c["e"] <= fn["e"]]


def unquote(lit):
    """Decode a Rust string literal (plain or raw) without evaluating code."""
    m = re.fullmatch(r'r(#*)"(.*)"\1', lit, re.S)
    if m:
        return m.group(2)
    if not lit.startswith('"'):
        return lit
    try:
        return json.loads(lit)
    except json.JSONDecodeError:  # Rust-only escapes such as \x1b or \u{..}
        return lit[1:-1]


# ── Constants: string, bool and integer literals only ─────────────────
def literal_value(text):
    """(ok, value) for a bare Rust literal."""
    t = text.strip()
    if t in ("true", "false"):
        return True, t == "true"
    if re.fullmatch(r"-?\d+", t):
        return True, int(t)
    if re.fullmatch(r'"(?:[^"\\]|\\.)*"|r#*".*"#*', t, re.S):
        return True, unquote(t)
    return False, None


consts = defaultdict(list)
for c in by_rule["const"]:
    ok, value = literal_value(c["mv"]["V"])
    if ok:
        consts[c["mv"]["ID"]].append(value)


def const_value(ident):
    """(ok, value) when `ident` names exactly one literal const."""
    values = consts.get(ident, [])
    return (True, values[0]) if len(values) == 1 else (False, None)


# ── F5: API drift guard ────────────────────────────────────────────────
trait_methods = {m["mv"]["NAME"] for m in by_rule["api-trait-method"] if m["file"] == API_FILE}
if trait_methods != EXPECTED_TRAIT_METHODS:
    fail("F5", f"ConfigRead/ConfigWrite methods changed: {sorted(trait_methods ^ EXPECTED_TRAIT_METHODS)}")
value_types = {m["mv"]["T"] for m in by_rule["api-value-type"] if m["file"] == API_FILE}
if value_types != EXPECTED_VALUE_TYPES:
    fail("F5", f"GetConfigValue impl types changed: {sorted(value_types ^ EXPECTED_VALUE_TYPES)}")

def producer_regex(names):
    return re.compile(r"\b(" + "|".join(sorted(names, key=len, reverse=True)) + r")\s*\(")


# A function returning a handle reads the chain of the base producer it
# calls, when it calls exactly one kind (create_isolated_config opens one
# file); otherwise its provenance is just its name.
base_re = producer_regex(BASE_PRODUCERS)
producers = dict(BASE_PRODUCERS)
for m in by_rule["fn-returns-config"]:
    name = m["mv"]["NAME"]
    if name in producers:
        continue
    kinds = {BASE_PRODUCERS[p] for c in within("producer-call", m) for p in base_re.findall(c["text"])} - {None}
    producers[name] = kinds.pop() if len(kinds) == 1 else f"via {name}"
producer_re = producer_regex(producers)

# ── F6: raw git2 config access outside the allowlist ──────────────────
for m in by_rule["raw-config"]:
    fn = enclosing("fn", m)
    name = fn["mv"]["NAME"] if fn else None
    if (m["file"], name) not in RAW_ALLOW and (m["file"], None) not in RAW_ALLOW:
        fail("F6", f"raw git2 config access {m['text']!r} at {m['file']}:{m['line']} in fn {name}")


# ── Receiver classification and handle provenance ─────────────────────
def split_args(text):
    """Top-level comma split of a call's `(...)` argument list."""
    inner, out, depth, cur, quote = text.strip()[1:-1], [], 0, "", False
    for i, ch in enumerate(inner):
        if ch == '"' and (i == 0 or inner[i - 1] != "\\"):
            quote = not quote
        elif not quote and ch in "([{<":
            depth += 1
        elif not quote and ch in ")]}>":
            depth -= 1
        elif not quote and ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
            continue
        cur += ch
    return out + ([cur.strip()] if cur.strip() else [])


def own_params(fn):
    return sorted((p for p in within("fn-param", fn) if enclosing("fn", p) is fn), key=lambda p: p["s"])


calls_to = defaultdict(list)
for call in by_rule["arg-call"]:
    calls_to[re.split(r"[.:]+", call["mv"]["F"])[-1]].append(call)


def handle_of(text, fn, before, depth=0):
    """The config chains an expression's handle reads, or None if it is not a
    config handle. `repository` is the repository's full chain, `global` the
    global/XDG/system chain without the repository, `file` one isolated file.
    A handle passed in as a parameter takes the chains of every caller's
    argument; `parameter` remains only when no caller resolves."""
    found = producer_re.findall(text)
    kinds = [producers[p] for p in found if producers[p]]
    if kinds:
        return {kinds[-1]}
    unwrapped = re.fullmatch(r"(.*)\.into_config\(\)\??", text.strip(), re.S)
    if unwrapped and depth <= 4:
        return handle_of(unwrapped.group(1), fn, before, depth + 1)
    if found:
        return {"unknown"}
    ident = text.strip().lstrip("&").removeprefix("mut ").strip()
    if not re.fullmatch(r"[A-Za-z_]\w*", ident) or depth > 4 or fn is None:
        return None
    params = own_params(fn)
    for index, p in enumerate(params):
        if p["mv"]["ID"].removeprefix("mut ").strip() != ident:
            continue
        if not re.search(r"\bConfig(Read)?\b", p["mv"]["T"]):
            return None
        chains = set()
        for call in calls_to[fn["mv"]["NAME"]]:
            call_args = split_args(call["mv"]["ARGS"])
            caller = enclosing("fn", call)
            if len(call_args) == len(params) and caller is not None:
                chains |= handle_of(call_args[index], caller, call["s"], depth + 1) or set()
        return chains or {"parameter"}
    lets = [l for l in within("let", fn)
            if l["mv"]["ID"].removeprefix("mut ").strip() == ident and l["s"] < before]
    if lets:
        last = max(lets, key=lambda l: l["s"])
        return handle_of(last["mv"]["V"], fn, last["s"], depth + 1)
    return None


# ── Key resolution ─────────────────────────────────────────────────────
def format_to_pattern(text):
    m = re.fullmatch(r'format!\(\s*("(?:[^"\\]|\\.)*")\s*(?:,\s*(.*))?\)', text, re.S)
    if not m:
        return None
    fmt = unquote(m.group(1))
    fmt_args = [a.strip() for a in (m.group(2) or "").split(",") if a.strip()]
    it = iter(fmt_args)
    return re.sub(r"\{(\w*)[^}]*\}", lambda g: f"<{g.group(1) or next(it, 'arg')}>", fmt)


def resolve_key(text, fn, before):
    """Return list of (key, provenance, extra) or None when unresolvable (F2)."""
    t = text.strip().lstrip("&")
    if t.startswith('"'):
        return [(unquote(t), "literal", {})]
    if t.startswith("format!"):
        p = format_to_pattern(t)
        return [(p, "format!", {})] if p else None
    m = re.fullmatch(r"([A-Za-z_]\w*)\.(\w+)\(\)", t)
    if m:  # method returning a key: enumerate its string match arms
        target = [f for f in by_rule["fn"] if f["mv"]["NAME"] == m.group(2)]
        out = []
        for f in target:
            arms, literal_arms = within("match-arm", f), within("match-arm-str", f)
            if len(arms) != len(literal_arms):
                odd = [a["mv"]["V"] for a in arms if (a["s"], a["e"]) not in {(x["s"], x["e"]) for x in literal_arms}]
                fail("F2", f"key-returning fn {m.group(2)} at {f['file']}:{f['line']} has non-literal match arms {odd!r}")
                return []
            for arm in literal_arms:
                variant = arm["mv"]["P"]
                vm = [v for v in by_rule["enum-variant"]
                      if v["mv"]["V"] == variant.split("::")[-1]
                      and v["mv"]["E"] == variant.split("::")[0]]
                doc = doc_above(vm[0]["file"], vm[0]["line"]) if vm else None
                out.append((unquote(arm["mv"]["V"]), f"match-arm {variant}", {"doc": doc, "variant": variant}))
        return out or None
    if re.fullmatch(r"[A-Za-z_]\w*", t):
        if fn:
            lets = [l for l in within("let", fn) if l["mv"]["ID"] == t and l["s"] < before]
            if lets:
                return resolve_key(max(lets, key=lambda l: l["s"])["mv"]["V"], fn, before)
        ok, value = const_value(t)
        if ok and isinstance(value, str):
            return [(value, f"const {t}", {})]
    return None


# ── Type and default inference ────────────────────────────────────────
def default_expr(text):
    """(ok, value) for a default expression: a literal, or a const that holds
    one, optionally converted to an owned string. Anything else is F12."""
    t = text.strip()
    t = re.sub(r"^String::from\((.*)\)$", r"\1", t, flags=re.S)
    t = re.sub(r"\.(to_string|to_owned|into)\(\)$", "", t)
    ok, value = literal_value(t)
    if ok:
        return ok, value
    if re.fullmatch(r"[A-Z_][A-Z0-9_]*", t):
        return const_value(t)
    return False, None


def value_type(value):
    return "bool" if isinstance(value, bool) else "int" if isinstance(value, int) else "string"


def annotated_type(call, fn):
    for l in within("let", fn):
        if l["s"] <= call["s"] and call["e"] <= l["e"] and "T" in l["mv"]:
            t = l["mv"]["T"]
            m = re.fullmatch(r"Option<(.+)>", t)
            return (m.group(1) if m else t), l["mv"]["ID"], l
    return None, None, None


def kebab(s):
    return re.sub(r"(?<!^)(?=[A-Z])", "-", s).lower()


def enum_values(name):
    variants = [v for v in by_rule["enum-variant"] if v["mv"]["E"] == name]
    if not any(d["mv"]["E"] == name for d in by_rule["derive-value-enum"]):
        return None
    return [{"value": kebab(v["mv"]["V"]), "description": doc_above(v["file"], v["line"])} for v in variants]


def none_default(fn, ident, after):
    arms = [a for a in within("none-arm", fn) if a["mv"].get("SUBJECT") == ident and a["s"] > after]
    return min(arms, key=lambda a: a["s"])["mv"]["D"] if arms else None


def parsed_enum(fn, ident, after):
    for fs in within("from-str", fn):
        if fs["s"] > after and re.match(rf"&?{ident}\b", fs["mv"].get("A", "") or fs["text"].split("(", 1)[1]):
            return fs["mv"]["ENUM"]
    return None


# ── Walk call sites ────────────────────────────────────────────────────
records = []
shape_spans = {(m["file"], m["s"], m["e"]) for rid in {**READ_SHAPES, **WRITE_SHAPES} for m in by_rule[rid]}

for c in by_rule["call-any"]:
    f = c["file"]
    if f == API_FILE:
        continue
    fn = enclosing("fn", c)
    if handle_of(c["mv"]["RECV"], fn, c["s"]) is None:
        continue
    if (f, c["s"], c["e"]) not in shape_spans:
        fail("F1", f"unrecognized call shape on a config handle: {c['text']!r} at {f}:{c['line']}")

for rid, method in {**READ_SHAPES, **WRITE_SHAPES}.items():
    for m in by_rule[rid]:
        f = m["file"]
        if f == API_FILE:
            continue
        fn = enclosing("fn", m)
        handle = handle_of(m["mv"]["RECV"], fn, m["s"]) if fn else None
        if handle is None:
            continue
        keys = resolve_key(m["mv"]["KEY"], fn, m["s"])
        if keys is None:
            fail("F2", f"unresolvable key expression {m['mv']['KEY']!r} at {f}:{m['line']}")
            continue
        for key, prov, extra in keys:
            rec = {"key": key, "access": "read" if rid in READ_SHAPES else "write",
                   "method": method, "file": f, "line": m["line"], "fn": fn["mv"]["NAME"],
                   "handles": handle, "key_from": prov, "type": None, "default": None,
                   "has_default": False, "values": None,
                   "doc": extra.get("doc") or doc_above(f, fn["line"]), "doc_from": "rustdoc"}
            if rid == "shape-get-turbofish":
                rec["type"] = m["mv"]["T"]
            if rid in ("shape-get-or", "shape-get-or-else"):
                d = m["mv"]["DEF"]
                if rid == "shape-get-or-else":
                    closure = re.fullmatch(r"\|\|\s*(?:\{\s*(.*?)\s*\}|(.*))", d.strip(), re.S)
                    d = (closure.group(1) or closure.group(2)) if closure else d
                ok, value = default_expr(d)
                if ok:
                    rec["type"], rec["default"], rec["has_default"] = value_type(value), value, True
                elif key.startswith("branchless."):
                    fail("F12", f"default {m['mv']['DEF']!r} for {key} at {f}:{m['line']} is neither a literal nor a literal const")
            if rid == "shape-list":
                rec["type"] = "String"  # (name, value) pairs of one family
            if rid in ("shape-get", "shape-get-turbofish"):
                t, ident, let = annotated_type(m, fn)
                if t and not rec["type"]:
                    rec["type"] = t
                if ident:
                    enum = parsed_enum(fn, ident, let["s"])
                    if enum:
                        rec["values"] = enum_values(enum)
                        rec["type"] = f"enum {enum}"
                    nd = none_default(fn, ident, let["s"])
                    if nd is not None:
                        nd = nd.strip()
                        if re.fullmatch(r"(return\s+)?(Ok\()?None\)?|None", nd):
                            pass  # unset
                        elif enum and nd.startswith(enum + "::"):
                            rec["default"], rec["has_default"] = kebab(nd.split("::")[1]), True
                        else:
                            ok, value = default_expr(nd)
                            if ok:
                                rec["default"], rec["has_default"] = value, True
                            elif key.startswith("branchless."):
                                fail("F12", f"None-arm default {nd!r} for {key} at {f}:{m['line']} is neither a literal, an enum variant nor a literal const")
            if rid == "shape-set":
                ok, value = literal_value(m["mv"]["VAL"])
                rec["type"] = value_type(value) if ok else None
            records.append(rec)

# ── F7: git subprocess `config` argv ───────────────────────────────────
for m in by_rule["git-argv-config"]:
    f = m["file"]
    fn = enclosing("fn", m)
    elements = re.findall(r'"((?:[^"\\]|\\.)*)"|([A-Za-z_][\w.]*)', m["text"])
    if any(ident for _, ident in elements):
        fail("F7", f"non-literal git config argv at {f}:{m['line']}: {m['text']!r}")
        continue
    argv = [s for s, _ in elements][1:]
    for k in [a for a in argv if "." in a and not a.startswith("-")]:
        records.append({"key": k, "access": "read", "method": "git-subprocess", "file": f,
                        "line": m["line"], "fn": fn["mv"]["NAME"] if fn else None,
                        "handles": {"git subprocess"}, "key_from": "argv-literal",
                        "type": argv[argv.index("--type") + 1] if "--type" in argv else "String",
                        "default": None, "has_default": False, "values": None,
                        "doc": doc_above(f, fn["line"]) if fn else None, "doc_from": "rustdoc"})

# ── F10: every obtained handle must lead to an extracted key ──────────
fns_with_records = {(r["file"], r["fn"]) for r in records}
for m in by_rule["producer-call"]:
    f = m["file"]
    if f == API_FILE:
        continue
    fn = enclosing("fn", m)
    name = fn["mv"]["NAME"] if fn else None
    if (f, name) in RAW_ALLOW or (f, name) in fns_with_records:
        continue
    # Otherwise the handle must be handed to a callee whose parameter is
    # Config-typed (e.g. create_isolated_config, install_alias); that callee
    # is then covered by receiver resolution.
    lets = [l for l in within("let", fn) if l["s"] <= m["s"] and m["e"] <= l["e"]] if fn else []
    token = re.escape(lets[0]["mv"]["ID"].removeprefix("mut ").strip()) if lets else None

    def config_callee(call):
        callee = re.split(r"[.:]+", call["mv"]["F"])[-1]
        return any(re.search(r"\bConfig(Read)?\b", q["mv"]["T"])
                   for g in by_rule["fn"] if g["mv"]["NAME"] == callee for q in within("param", g))
    handed = any(config_callee(c) and (c["s"] <= m["s"] and m["e"] <= c["e"]
                                       or (token and re.search(rf"\b{token}\b", c["mv"]["ARGS"])))
                 for c in (within("arg-call", fn) if fn else []))
    if not handed:
        fail("F10", f"config handle {m['text']!r} obtained at {f}:{m['line']} in fn {name} but no key extracted there")
for m in by_rule["field-config"]:
    if m["file"] != API_FILE:
        fail("F10", f"struct field {m['mv']['ID']}: {m['mv']['T']} at {m['file']}:{m['line']} stores a config handle; extend receiver resolution")
for m in by_rule["ufcs-config"]:
    if m["file"] == API_FILE or re.match(r"Config::(open|open_default|from)\b", m["text"]):
        continue
    fail("F1", f"UFCS config call {m['text'][:60]!r} at {m['file']}:{m['line']}")

# ── Normalization (all derived from AST captures above) ───────────────
enum_doc = {d["mv"]["E"]: doc_above(d["file"], d["line"]) for d in by_rule["derive-value-enum"]}
for r in records:
    r["key_raw"] = r["key"]
    # Dynamic segments and list globs become one `<name>` family.
    r["key"] = re.sub(r"<[^>]*>", "<name>", r["key"])
    if r["method"] == "list" and r["key"].endswith(".*"):
        r["key"] = r["key"][:-2] + ".<name>"
    # Rustdoc is only trusted on accessor functions (`get_*`) or when it came
    # from an enum variant; otherwise it describes the caller, not the key.
    if r["doc"] and "match-arm" not in r["key_from"] and not (r["fn"] or "").startswith("get_"):
        r["doc"] = None
    if r["type"] and r["type"].startswith("enum "):
        r["doc"] = enum_doc.get(r["type"][5:])
all_docs = " ".join(r["doc"] or "" for r in records)

# ── F8: key-shaped consts nothing reads ───────────────────────────────
annotations = json.loads(args.annotations.read_text())
dead_annotated = annotations.get("deadKeys", {})
read_raw = {r["key_raw"] for r in records}
dead = {}
for c in by_rule["const"]:
    ok, value = literal_value(c["mv"]["V"])
    if ok and isinstance(value, str) and re.fullmatch(r"branchless\.[\w.]+", value) and value not in read_raw:
        if value in dead_annotated:
            dead[value] = {"const": c["mv"]["ID"], "file": c["file"], "reason": dead_annotated[value]}
        else:
            fail("F8", f"key-shaped const {c['mv']['ID']} = {value!r} at {c['file']}:{c['line']} is never read; "
                       "extend the resolver, or record it under deadKeys in annotations.json")
for k in sorted(set(dead_annotated) - set(dead)):
    fail("F4", f"deadKeys entry {k} is stale: no unread const holds it any more")

# ── Aggregate the sites into one record per key ───────────────────────
by_key = defaultdict(list)
for r in records:
    by_key[r["key"]].append(r)


def site(r):
    return f"{r['file']}#{r['fn']}" if r["fn"] else r["file"]


def sites(rs, access):
    """site → the config chains that site's handle reads (see handle_of)."""
    out = defaultdict(set)
    for r in rs:
        if r["access"] == access:
            out[site(r)] |= r["handles"]
    return {s: sorted(h) for s, h in sorted(out.items())}


def agree(key, field, values, code="F13"):
    distinct = []
    for v in values:
        if v not in distinct:
            distinct.append(v)
    if len(distinct) > 1:
        fail(code, f"{key} has conflicting {field}: {distinct!r}")
    return distinct[0] if distinct else None


settings, foreign = {}, {}
for key, rs in sorted(by_key.items()):
    entry = {access + "s": sites(rs, access) for access in ("read", "write")}
    if not key.startswith("branchless."):
        foreign[key] = entry
        continue
    rd = [r for r in rs if r["access"] == "read"] or rs
    raw_type = agree(key, "types", [r["type"] for r in rd if r["type"]])
    if raw_type and raw_type.startswith("enum "):
        entry["type"] = "enum"
        entry["values"] = agree(key, "enum values", [r["values"] for r in rd if r["values"]])
    elif raw_type:
        entry["type"] = RUST_TYPES.get(raw_type, raw_type)
    defaults = [r["default"] for r in rd if r["has_default"]]
    if defaults:
        entry["default"] = agree(key, "defaults", defaults)
    docs = sorted({r["doc"] for r in rd if r["doc"]})
    if docs:
        entry["description"] = docs[0]
    entry["status"] = "legacy" if re.search(r"\(deprecated\)\s*" + re.escape(key) + r"(?![\w.])", all_docs) else "current"
    settings[key] = entry

# ── Annotations: fill what the source cannot state ────────────────────
# An annotation may only FILL a field the source left empty, or replace one
# it names in `replace`, so a later upstream change cannot be masked (F4).
# `defaultDescription` and `note` are prose the source never carries.
for key, ann in sorted(annotations.get("settings", {}).items()):
    if key not in settings:
        fail("F4", f"annotation for {key} is stale: the source no longer reads it")
        continue
    entry = settings[key]
    for fld, value in ann.items():
        if fld in ("replace",):
            continue
        if fld in ("defaultDescription", "note") or entry.get(fld) is None or fld in ann.get("replace", []):
            entry[fld] = value
        elif entry[fld] != value:
            fail("F4", f"annotation {key}.{fld}={value!r} shadows extracted {entry[fld]!r}; list it in replace")
    for fld in ann.get("replace", []):
        if fld not in ann:
            fail("F4", f"annotation {key} replaces {fld} without giving a value")

# ── F3: a setting with no type is a hard failure ──────────────────────
for key, entry in settings.items():
    if entry["reads"] and "type" not in entry:
        fail("F3", f"no type for read of {key} (add one to annotations.json)")

# ── F9: every key named in a production string literal is accounted for
families = [re.compile(re.escape(k[: -len("<name>")]) + r".+") for k in by_key if k.endswith("<name>")]
known = set(by_key) | read_raw | set(dead)
for lit in by_rule["key-literal"]:
    for token in KEY_TOKEN.findall(unquote(lit["text"])):
        token = token.rstrip(".")
        norm = re.sub(r"\{[^}]*\}|<[^>]*>|\*", "<name>", token)
        if norm in known or token in known or any(p.fullmatch(token) for p in families):
            continue
        fail("F9", f"string literal at {lit['file']}:{lit['line']} names {token}, which no recognised read or write extracts")

# ── F14: builtin revset functions, and that they shadow aliases ───────
tables = by_rule["revset-functions-table"]
revset_functions = sorted({unquote(m["text"]) for m in by_rule["revset-function"]})
if len(tables) != 1:
    fail("F14", f"expected one `static ref FUNCTIONS` table, found {len(tables)}")
else:
    entries = len(re.findall(r'\(\s*"', tables[0]["text"]))
    if entries != len(by_rule["revset-function"]):
        fail("F14", f"FUNCTIONS has {entries} entries but only {len(by_rule['revset-function'])} have the (\"name\", &fn) shape")
alias_reads = [r for r in records if r["key"] == "branchless.revsets.alias.<name>" and r["access"] == "read"]
for r in alias_reads:
    first = [m for m in by_rule["functions-lookup"] if m["file"] == r["file"]
             and m["line"] < r["line"] and (enclosing("fn", m) or {"mv": {}})["mv"].get("NAME") == r["fn"]]
    if not first:
        fail("F14", f"{r['file']}#{r['fn']} no longer consults FUNCTIONS before branchless.revsets.alias.*; "
                    "the builtin-name rule in lib/settings.nix may be wrong")

# ── Shape floor ───────────────────────────────────────────────────────
current = [k for k, e in settings.items() if e["reads"] and e["status"] == "current"]
if len(current) < MIN_SETTINGS:
    fail("F15", f"only {len(current)} current settings extracted (floor {MIN_SETTINGS})")
if len(revset_functions) < MIN_REVSET_FUNCTIONS:
    fail("F15", f"only {len(revset_functions)} builtin revset functions extracted (floor {MIN_REVSET_FUNCTIONS})")

sidecar = {
    "deadKeys": dict(sorted(dead.items())),
    "foreign": foreign,
    "revsetFunctions": revset_functions,
    "settings": settings,
    "source": {"version": tomllib.loads((SRC / "git-branchless/Cargo.toml").read_text())["package"]["version"]},
}
args.out.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")

for key, e in sorted(settings.items()):
    print(f"{key:52} {e.get('type', '-')!s:7} {e['status']:7} default={json.dumps(e.get('default'))[:40]:42} "
          f"read via {','.join(sorted(set().union(*e['reads'].values())))}")
print(f"\n{len(records)} key sites, {len(settings)} settings, {len(foreign)} foreign keys, "
      f"{len(revset_functions)} builtin revset functions")
for x in failures:
    print("FAIL", x, file=sys.stderr)
sys.exit(1 if failures else 0)
