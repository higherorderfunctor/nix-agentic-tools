#!/usr/bin/env python3
# cspell:ignore astext autoclass automodule dests doctree elts finalbody kwonlyargs orelse toctree vararg  (Python ast / docutils / upstream names)
"""Census of the git config keys git-revise reads.

Input : the source tree the package builds (--src), and docutils on
        PYTHONPATH.
Output: extracted.json in the shared sidecar schema (lib/git-tool-settings):
        facts only. An owned key the man page does not describe has no
        `description`, and a key-shaped string no read covers is a dead key
        with no reason. Hand annotations may add prose in Nix
        (lib/git-tool-settings/rules.nix).
Exit  : non-zero when any guard trips:
  R1  `git config` or `git -c` reached outside the helpers, or a git argv
      the extractor cannot read (a non-literal before the subcommand, a
      splat that is not a wrapper forwarding its own parameter, an argv name
      assigned more than once)
  R2  a helper call whose key is not a literal, that splats its arguments,
      or that passes no default
  R3  a helper whose `git config` type flag is unknown
  R5  the helper API drifted (signature, try/except shape, argv, wrapping)
  R6  a helper used as a value, or named through getattr/hasattr
  R7  one key under two spellings, or with conflicting types or defaults
  R11 an override through an `args.X` the CLI parser does not define
  R13 GIT_CONFIG* in code: config through the environment is not modelled
  R14 `git var` of a variable outside VAR_ALLOWED (it reads config git-revise
      does not model)
  R15 a floor is missed

Method order, as the repo requires:
  eval    `build_parser()` is imported from the pinned source and asked for
          its own flags (dest -> option strings).
  AST     Python's `ast` for every config read, its key, type, default,
          fallback chain and CLI override; docutils for the man page's
          `.. gitconfig::` directives.
  regex   only the shared key-token net (census.py), run over decoded AST
          string constants.
"""

import argparse
import ast
import importlib
import json
import sys
from collections import defaultdict
from pathlib import Path

from census import Census, sites

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--src", type=Path, required=True)
args = parser.parse_args()
SRC = args.src
PKG = "gitrevise"
MAN = "docs/man.rst"
# `git config` flags that fix the type git hands back. Anything else a helper
# passes is unknown and fails R3.
TYPE_FLAGS = {(): "string", ("--bool",): "bool", ("--int",): "int", ("--path",): "path"}
# How each type's helper must wrap the git call's bytes (R5).
WRAPS = {"string": "raw", "bool": "eq-true", "int": "int()", "path": "raw"}
# Functions that spawn a process. A git argv reaching one of these outside
# Repository.git is a read path the helpers do not see (R1).
RUNNERS = {"Popen", "call", "check_call", "check_output", "run", "sh_run"}
# `git var` variables git-revise may ask for: each reads config git owns
# (core.editor, user.*, author.*, committer.*). A new one reads config this
# census would otherwise not know about (R14).
VAR_ALLOWED = {"GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT", "GIT_EDITOR"}
MIN_SETTINGS = 2  # the pinned release reads 3 revise.* keys
MIN_READS = 10  # and 15 keys in all

census = Census("revise")
fail = census.fail

# ── Parse the package ──────────────────────────────────────────────────
modules = {}
for path in sorted((SRC / PKG).rglob("*.py")):
    rel = str(path.relative_to(SRC))
    modules[rel] = ast.parse(path.read_text(), filename=rel)
if not modules:
    fail("R15", f"no Python modules under {PKG}/")

parents = {}
for tree in modules.values():
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[child] = node


def ancestors(node):
    while node in parents:
        node = parents[node]
        yield node


def enclosing_fn(node):
    return next((a for a in ancestors(node) if isinstance(a, (ast.FunctionDef, ast.AsyncFunctionDef))), None)


def enclosing_class(node):
    return next((a for a in ancestors(node) if isinstance(a, ast.ClassDef)), None)


def qualname(fn):
    cls = enclosing_class(fn) if fn else None
    return f"{cls.name}.{fn.name}" if cls else (fn.name if fn else "<module>")


def const(node):
    """(ok, python value) for a literal; bytes decode to str."""
    if isinstance(node, ast.Constant):
        v = node.value
        return True, v.decode() if isinstance(v, bytes) else v
    return False, None


def local_assign(fn, name, before):
    """The one `name = <expr>` in fn above line `before`. A name assigned in
    several places (an if/else, a loop) has no single argv: R1."""
    found = [n for n in ast.walk(fn) if isinstance(n, (ast.Assign, ast.AnnAssign)) and n.lineno < before
             and any(isinstance(t, ast.Name) and t.id == name
                     for t in (n.targets if isinstance(n, ast.Assign) else [n.target]))]
    if len(found) > 1:
        fail("R1", f"{name} is assigned {len(found)} times in {qualname(fn)}; its argv is not one list")
        return None
    return found[0].value if found else None


def own_parameter(fn, name):
    return fn is not None and name in {a.arg for a in [*fn.args.args, *fn.args.kwonlyargs]} | \
        ({fn.args.vararg.arg} if fn.args.vararg else set())


# ── R5/R3: discover the config helpers from their own bodies ──────────
def helper_shape(fn, rel):
    """(type, key parameter) if fn is a `git config --get` helper, None if it
    is not one; R3/R5 when it touches `git config` in an unknown shape."""
    calls = [c for c in ast.walk(fn) if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute)
             and c.func.attr == "git" and c.args and const(c.args[0]) == (True, "config")]
    if not calls:
        return None
    where = f"{fn.name} at {rel}:{fn.lineno}"
    params = [a.arg for a in fn.args.args]
    if len(calls) != 1 or len(params) != 3 or params[0] != "self" or params[2] != "default":
        fail("R5", f"config helper {where} no longer has the (self, key, default) shape")
        return None
    body = fn.body[1:] if isinstance(fn.body[0], ast.Expr) else fn.body  # skip a docstring
    if len(body) != 1 or not isinstance(body[0], ast.Try):
        fail("R5", f"config helper {where} is no longer a single try/except")
        return None
    tr = body[0]
    handler_ok = (len(tr.handlers) == 1 and isinstance(tr.handlers[0].type, ast.Name)
                  and tr.handlers[0].type.id == "CalledProcessError"
                  and len(tr.handlers[0].body) == 1 and isinstance(tr.handlers[0].body[0], ast.Return)
                  and isinstance(tr.handlers[0].body[0].value, ast.Name)
                  and tr.handlers[0].body[0].value.id == "default")
    if not handler_ok or len(tr.body) != 1 or not isinstance(tr.body[0], ast.Return) or tr.orelse or tr.finalbody:
        fail("R5", f"config helper {where}: default is no longer 'return default on CalledProcessError'")
        return None
    call = calls[0]
    lits = [const(a) for a in call.args[:-1]]
    last = call.args[-1]
    if not all(ok for ok, _ in lits) or not isinstance(last, ast.Name) or last.id != params[1] or call.keywords:
        fail("R5", f"config helper {where}: git argv is no longer literals + the key parameter")
        return None
    argv = [v for _, v in lits]
    if argv[:2] != ["config", "--get"]:
        fail("R3", f"config helper {where}: argv {argv} is not `config --get ...`")
        return None
    flags = tuple(argv[2:])
    if flags not in TYPE_FLAGS:
        fail("R3", f"config helper {where}: unknown git config type flags {list(flags)}")
        return None
    typ = TYPE_FLAGS[flags]
    ret = tr.body[0].value
    if ret is call:
        wrap = "raw"
    elif (isinstance(ret, ast.Compare) and ret.left is call and len(ret.ops) == 1
          and isinstance(ret.ops[0], ast.Eq) and const(ret.comparators[0]) == (True, "true")):
        wrap = "eq-true"
    elif isinstance(ret, ast.Call) and isinstance(ret.func, ast.Name) and ret.func.id == "int" and ret.args == [call]:
        wrap = "int()"
    else:
        wrap = ast.unparse(ret)
    if wrap != WRAPS[typ]:
        fail("R5", f"config helper {where}: {typ} value is wrapped as {wrap!r}, expected {WRAPS[typ]}")
        return None
    return typ, params[1]


helpers = {}
for rel, tree in modules.items():
    for fn in ast.walk(tree):
        if isinstance(fn, ast.FunctionDef):
            shape = helper_shape(fn, rel)
            if shape:
                cls = enclosing_class(fn)
                if not cls or cls.name != "Repository":
                    fail("R5", f"config helper {fn.name} at {rel}:{fn.lineno} is not a Repository method")
                helpers[fn.name] = {"type": shape[0], "key_param": shape[1], "node": fn}
if not helpers:
    fail("R15", "no `git config --get` helper found on Repository")


def in_helper(node):
    fn = enclosing_fn(node)
    return fn is not None and any(h["node"] is fn for h in helpers.values())


# ── R1: every other way to reach `git config` fails closed ────────────
# The net: the literal "config" appears nowhere but a helper's argv. It sees
# an argv built in pieces, from a variable, or after global options.
for rel, tree in modules.items():
    for n in ast.walk(tree):
        if const(n) == (True, "config") and not in_helper(n):
            fail("R1", f"\"config\" at {rel}:{n.lineno} outside the config helpers")


def git_argv(elements, fn, where):
    """Literal git arguments, or None (after R1) when one cannot be read.
    A splat is readable only when it forwards the function's own parameter
    (a wrapper; its callers are checked) or names a single local list."""
    out = []
    for e in elements:
        if isinstance(e, ast.Starred):
            if isinstance(e.value, ast.Name) and own_parameter(fn, e.value.id):
                return out + [None]
            resolved = local_assign(fn, e.value.id, e.lineno) if fn and isinstance(e.value, ast.Name) else None
            inner = resolved.elts if isinstance(resolved, (ast.List, ast.Tuple)) else None
            if inner is None:
                fail("R1", f"cannot read the splat {ast.unparse(e)!r} of a git argv at {where}")
                return None
            sub = git_argv(inner, fn, where)
            if sub is None:
                return None
            out += sub
        else:
            ok, v = const(e)
            out.append(v if ok else None)
    return out


def check_git(argv, where, wrapper):
    """argv excludes the leading "git". None entries are non-literals."""
    head = next((i for i, a in enumerate(argv) if a is None or not str(a).startswith("-")), None)
    if head is None or argv[head] is None:
        if not wrapper:
            fail("R1", f"cannot tell which git subcommand runs at {where}")
        return
    literal = [a for a in argv if isinstance(a, str)]
    if "-c" in argv[:head] or any(a.startswith("--config-env") for a in literal):
        fail("R1", f"git -c at {where}: config injected on the command line is not modelled")
    if argv[head] == "var":
        for name in argv[head + 1:]:
            if name not in VAR_ALLOWED:
                fail("R14", f"git var {name!r} at {where} is outside {sorted(VAR_ALLOWED)}")


for rel, tree in modules.items():
    for c in ast.walk(tree):
        if not isinstance(c, ast.Call):
            continue
        fn = enclosing_fn(c)
        where = f"{rel}:{c.lineno}"
        name = c.func.attr if isinstance(c.func, ast.Attribute) else getattr(c.func, "id", None)
        # R6: a helper named through getattr/hasattr cannot be followed.
        if name in ("getattr", "hasattr") and len(c.args) >= 2 and const(c.args[1])[1] in helpers:
            fail("R6", f"config helper {const(c.args[1])[1]} named through {name}() at {where}")
        if name == "git" and isinstance(c.func, ast.Attribute):
            if in_helper(c):
                continue
            argv = git_argv(c.args, fn, where)
            forwarding = bool(argv) and argv[-1] is None and fn is not None and fn.name == "git"
            if argv is not None:
                check_git(argv, where, forwarding)
        elif name in RUNNERS and c.args:
            argv_expr = c.args[0]
            if isinstance(argv_expr, ast.Name):
                if own_parameter(fn, argv_expr.id):
                    continue  # a runner wrapper forwarding its own parameter; its callers are checked
                argv_expr = local_assign(fn, argv_expr.id, c.lineno) if fn else None
                if argv_expr is None:
                    fail("R1", f"cannot resolve the argv of {name}() at {where}")
                    continue
            if isinstance(argv_expr, ast.BinOp) and isinstance(argv_expr.op, ast.Add):
                argv_expr = argv_expr.left
            if not isinstance(argv_expr, (ast.List, ast.Tuple)):
                fail("R1", f"cannot read the argv of {name}() at {where}: {ast.unparse(argv_expr)[:60]!r}")
                continue
            argv = git_argv(argv_expr.elts, fn, where)
            if argv and argv[0] == "git":
                check_git(argv[1:], where, False)

# R13: config injected through the environment would bypass everything above.
for rel, tree in modules.items():
    for n in ast.walk(tree):
        ok, v = const(n)
        if ok and isinstance(v, str) and (v == "GIT_CONFIG" or v.startswith("GIT_CONFIG_")):
            fail("R13", f"{v} set or read at {rel}:{n.lineno}; config via environment is not modelled")

# ── Walk the helper call sites ─────────────────────────────────────────
records = []
call_record = {}


def classify_default(expr):
    """('literal', v) | ('fallback', call) | ('computed', source text)."""
    ok, v = const(expr)
    if ok:
        return "literal", v
    if isinstance(expr, ast.Call) and isinstance(expr.func, ast.Attribute) and expr.func.attr in helpers:
        return "fallback", expr
    return "computed", ast.unparse(expr)


for rel, tree in modules.items():
    for c in ast.walk(tree):
        # R6: a helper used as a value rather than called cannot be followed.
        if isinstance(c, ast.Attribute) and c.attr in helpers:
            parent = parents.get(c)
            if not (isinstance(parent, ast.Call) and parent.func is c):
                fail("R6", f"config helper {c.attr} used as a value at {rel}:{c.lineno}: {ast.unparse(parent)[:60]!r}")
    for c in ast.walk(tree):
        if not (isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr in helpers):
            continue
        h = helpers[c.func.attr]
        where = f"{rel}:{c.lineno}"
        kw = {k.arg: k.value for k in c.keywords}
        if any(k is None for k in kw) or any(isinstance(a, ast.Starred) for a in c.args):
            fail("R2", f"*args/**kwargs call to {c.func.attr} at {where}")
            continue
        key_expr = c.args[0] if c.args else kw.get(h["key_param"])
        default_expr = c.args[1] if len(c.args) > 1 else kw.get("default")
        ok, key = const(key_expr) if key_expr is not None else (False, None)
        if not ok or not isinstance(key, str):
            fail("R2", f"key of {c.func.attr} at {where} is not a string literal: "
                       f"{ast.unparse(key_expr) if key_expr is not None else None!r}")
            continue
        if default_expr is None:
            fail("R2", f"{c.func.attr}({key!r}) at {where} has no default")
            continue
        kind, dv = classify_default(default_expr)
        fn = enclosing_fn(c)
        rec = {"key": key, "type": h["type"], "helper": c.func.attr, "file": rel, "line": c.lineno,
               "fn": qualname(fn), "fn_node": fn, "call": c, "access": "read", "handles": ["repository"],
               "default_kind": kind, "default": dv if kind != "fallback" else None,
               "fallback_call": dv if kind == "fallback" else None}
        records.append(rec)
        call_record[id(c)] = rec

# Resolve fallback chains: the default of a read is another read's result.
for r in records:
    chain, cur = [], r
    while cur["default_kind"] == "fallback":
        nxt = call_record.get(id(cur["fallback_call"]))
        if nxt is None:
            fail("R2", f"fallback of {r['key']} at {r['file']}:{r['line']} was not extracted")
            break
        chain.append(nxt["key"])
        cur = nxt
    r["fallback"] = chain
    r["terminal"] = (cur["default_kind"], cur["default"])


# ── Values the code compares a read against, and Enum-parsed values ───
def uses_of(rec):
    """Expressions that consume the read: the call itself, or a local it is
    assigned to (followed through `.decode()`)."""
    c, fn = rec["call"], rec["fn_node"]
    exprs = [c]
    parent = parents.get(c)
    target = None
    if isinstance(parent, ast.Assign):
        target = parent.targets[0]
    elif isinstance(parent, ast.Attribute) and parent.attr == "decode":
        grandparent = parents.get(parents.get(parent))
        if isinstance(grandparent, ast.Assign):
            target = grandparent.targets[0]
    if isinstance(target, ast.Name) and fn is not None:
        exprs += [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == target.id
                  and isinstance(n.ctx, ast.Load) and n.lineno >= c.lineno]
    return exprs, target


def compared_values(rec):
    exprs, _ = uses_of(rec)
    out = set()
    for e in exprs:
        p = parents.get(e)
        if isinstance(p, ast.Compare) and len(p.ops) == 1 and isinstance(p.ops[0], (ast.Eq, ast.NotEq)):
            other = p.comparators[0] if p.left is e else p.left
            ok, v = const(other)
            if ok and isinstance(v, str):
                out.add(v)
    return sorted(out)


def is_enum_base(base):
    return (isinstance(base, ast.Name) and base.id == "Enum") or (isinstance(base, ast.Attribute) and base.attr == "Enum")


def enum_values(rec):
    """`cls.__members__.get(<read>.upper())` inside an Enum classmethod."""
    fn = rec["fn_node"]
    cls = enclosing_class(fn) if fn else None
    if not cls or not any(is_enum_base(b) for b in cls.bases):
        return None
    if not any(isinstance(n, ast.Attribute) and n.attr == "__members__" for n in ast.walk(fn)):
        return None
    names = [t.id for s in cls.body if isinstance(s, ast.Assign) for t in s.targets if isinstance(t, ast.Name)]
    return [{"value": n.lower()} for n in sorted(names, key=str.lower)]


# ── Eval: the program's own CLI schema ─────────────────────────────────
sys.path.insert(0, str(SRC))
try:
    cli = importlib.import_module(f"{PKG}.tui").build_parser()
except Exception as err:  # noqa: BLE001 -- any import failure is a guard failure
    fail("R11", f"could not import {PKG}.tui.build_parser from the source: {err!r}")
    cli = None
flags_by_dest = {}
if cli:
    for action in cli._actions:  # argparse exposes no public iterator
        if action.option_strings:
            flags_by_dest[action.dest] = action.option_strings


def args_tests(node):
    """dests of `args.<dest>` referenced in node."""
    return {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute)
            and isinstance(n.value, ast.Name) and n.value.id == "args"}


def overridden_by(rec):
    """CLI flags that decide before, or overwrite after, this read."""
    dests = set()
    fn = rec["fn_node"]
    # (a) an `if args.X:` that returns before the read, in the same function
    for n in ast.walk(fn) if fn else []:
        if isinstance(n, ast.If) and n.lineno < rec["line"] and any(isinstance(s, ast.Return) for s in n.body):
            dests |= args_tests(n.test)
    # (b) the read is stored on an attribute that an `if args.X:` overwrites
    top = rec["call"]
    while parents.get(top) is not None and not isinstance(parents.get(top), ast.Assign):
        p = parents.get(top)
        if isinstance(p, (ast.stmt, ast.FunctionDef)):
            break
        top = p
    assign = parents.get(top)
    if isinstance(assign, ast.Assign) and isinstance(assign.targets[0], ast.Attribute):
        attr = assign.targets[0].attr
        for tree in modules.values():
            for n in ast.walk(tree):
                if isinstance(n, ast.If) and any(isinstance(s, ast.Assign) and isinstance(s.targets[0], ast.Attribute)
                                                  and s.targets[0].attr == attr for s in n.body):
                    dests |= args_tests(n.test)
    flags = []
    for d in sorted(dests):
        if d not in flags_by_dest:
            fail("R11", f"{rec['key']} is overridden by args.{d}, which the CLI parser does not define")
            continue
        flags += flags_by_dest[d]
    return sorted(flags)


# ── Descriptions: the man page's gitconfig directives, via docutils ───
def parse_man():
    from docutils import nodes
    from docutils.core import publish_doctree
    from docutils.parsers.rst import Directive, directives, roles

    class GitConfig(Directive):
        required_arguments = 1
        has_content = True

        def run(self):
            node = nodes.container(classes=["gitconfig"])
            node["key"] = self.arguments[0]
            self.state.nested_parse(self.content, self.content_offset, node)
            return [node]

    class Opaque(Directive):  # Sphinx-only directives the census does not need
        required_arguments = 0
        optional_arguments = 9
        final_argument_whitespace = True
        has_content = True

        def run(self):
            return []

    def literal_role(name, rawtext, text, lineno, inliner, options=None, content=None):
        # A Sphinx cross-reference `title <target>` shows only its title.
        title, _, target = text.rpartition(" <")
        return [nodes.literal(rawtext, title if title and target.endswith(">") else text)], []

    directives.register_directive("gitconfig", GitConfig)
    for d in ("option", "program", "toctree", "autoclass", "automodule"):
        directives.register_directive(d, Opaque)
    for r in ("option", "manpage", "ref", "command", "envvar"):
        roles.register_local_role(r, literal_role)

    doctree = publish_doctree((SRC / MAN).read_text(), source_path=str(SRC / MAN),
                              settings_overrides={"report_level": 5, "halt_level": 5})

    def render(node):
        if isinstance(node, nodes.literal):
            return f"`{node.astext()}`"
        if isinstance(node, nodes.Text):
            return str(node)
        return "".join(render(ch) for ch in node.children)

    found = {}
    for node in doctree.findall(nodes.container):
        if "gitconfig" in node["classes"]:
            found[node["key"]] = " ".join(" ".join(render(p) for p in node.findall(nodes.paragraph)).split())
    return found


man_docs = parse_man()

# ── Aggregate per key ──────────────────────────────────────────────────
by_key = defaultdict(list)
for r in records:
    by_key[r["key"]].append(r)
# git config keys are case-insensitive in section and name: two spellings of
# one key would silently split its record.
fold = defaultdict(set)
for k in by_key:
    fold[k.lower()].add(k)
for spellings in fold.values():
    if len(spellings) > 1:
        fail("R7", f"one key read under several spellings: {sorted(spellings)}")

settings, foreign = {}, {}
for key, rs in sorted(by_key.items()):
    entry = {"reads": sites(rs, "read"), "writes": {}}
    entry["type"] = census.agree(key, "types", [r["type"] for r in rs], "R7")
    fallback = census.agree(key, "fallback chains", [r["fallback"] for r in rs], "R7")
    if fallback:
        entry["fallback"] = fallback
    kind, value = census.agree(key, "terminal defaults", [r["terminal"] for r in rs], "R7")
    if kind == "literal":
        if value is not None:
            entry["default"] = value
    else:
        entry["defaultExpr"] = value
    values = census.agree(key, "enum values", [v for v in (enum_values(r) for r in rs) if v], "R7")
    if values:
        entry["type"], entry["values"] = "enum", values
    compares = sorted({v for r in rs for v in compared_values(r)})
    if compares and not values:
        entry["specialValues"] = compares
    flags = sorted({f for r in rs for f in overridden_by(r)})
    if flags:
        entry["overriddenBy"] = flags
    if census.owns(key):
        entry["documented"] = key in man_docs
        if key in man_docs:
            entry["description"] = man_docs[key]
        entry["status"] = "current"
        # An unparsable bool or int makes `git config --bool/--int` fail, and
        # the helper returns its default: the fallback key's value when
        # there is one.
        if entry["type"] in ("bool", "int"):
            entry["invalid"] = "fallback" if fallback else "default"
        settings[key] = entry
    else:
        foreign[key] = entry

# ── Dead keys: production strings no read covers ───────────────────────
# A production string naming a key no read covers is a dead key: a
# mention, or a read this extractor cannot see.
known = {k.lower() for k in by_key}
dead = {}
for rel, tree in modules.items():
    for n in ast.walk(tree):
        ok, v = const(n)
        if not (ok and isinstance(v, str)):
            continue
        for token in census.key_tokens(v):
            if token.lower() not in known:
                dead[token] = {"file": rel}

# ── Floors ─────────────────────────────────────────────────────────────
if len(settings) < MIN_SETTINGS:
    fail("R15", f"only {len(settings)} revise.* settings extracted (floor {MIN_SETTINGS})")
if len(by_key) < MIN_READS:
    fail("R15", f"only {len(by_key)} keys extracted (floor {MIN_READS})")

init = modules.get(f"{PKG}/__init__.py")
version = None
for n in ast.walk(init) if init else []:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__version__" for t in n.targets):
        version = const(n.value)[1]
if not isinstance(version, str):
    fail("R15", f"no literal __version__ in {PKG}/__init__.py")

for key, e in sorted({**settings, **foreign}.items()):
    fb = "<-" + ",".join(e.get("fallback", [])) if e.get("fallback") else ""
    d = e.get("default", e.get("defaultExpr"))
    print(f"{key:20} {e['type']:7} default={json.dumps(d)!s:22} {fb:22} "
          f"{'owned' if key in settings else 'foreign'} overriddenBy={','.join(e.get('overriddenBy', [])) or '-'}")
unused = sorted(set(helpers) - {r["helper"] for r in records})
print(f"\n{len(records)} read sites, {len(settings)} settings, {len(foreign)} foreign keys, "
      f"helpers={sorted(helpers)} unused={unused}")

census.finish(args.out, {
    "deadKeys": dict(sorted(dead.items())),
    "foreign": foreign,
    "settings": settings,
    "source": {"version": version},
})
