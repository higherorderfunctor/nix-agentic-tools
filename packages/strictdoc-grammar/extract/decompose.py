# cspell:ignore lookaheads sgra strmatching textx
"""Decompose faithful's raw rule records into Nix type expressions.

Owned by ``normalize.py``. ``extract.py`` must never import this module: the
faithful surface's whole promise is that nothing was transformed, and a record
of transformations — a dialect rewrite, a lookahead lifted out of a pattern, a
literal set turned into a vocabulary — is exactly a transformation. It belongs
one layer up, with the converters, and this module is where it lives.

Two things are decided here, and neither is a re-derivation.

── The regex dialect ────────────────────────────────────────────────────────

Nix's regex engine is POSIX ERE and StrictDoc's patterns are Python's.
``builtins.match`` rejects lookahead, ``\\S`` and backreferences outright —
MEASURED — so a literal transcription of ``FieldName``'s pattern would produce a
type that throws the moment anything is checked against it. Every pattern
therefore carries BOTH spellings: ``source`` is upstream's, verbatim and
authoritative, and ``ere`` is a mechanical dialect rewrite whose every step is
named in ``rewrites``. The rewrites are exact, never widening: a leading
``(?!DOCUMENT)`` becomes an explicit ``deny`` prefix rather than being dropped,
and a construct no named rewrite claims is an ERROR, not a fallback to free
text.

── Which line-anchored denials are enforced ─────────────────────────────────

arpeggio compiles every ``RegExMatch`` with ``re.MULTILINE`` and applies it with
``regex.match(input, pos)``, so a ``^``-anchored lookahead holds only where
``pos`` is a line start. That makes such a lookahead POSITIONAL — but it does
not make it inert, and the two words ``FieldName`` denies are not the same kind
of thing.

The discriminator, settled with the operator: **run each denied word against the
SIBLING ALTERNATIVES of the rule that denies it.** A word that appears as an
alternative is a BACKTRACKING GUARD — the lookahead exists so the parser does
not swallow a token another branch is waiting for — and enforcing it as a value
constraint would reject something legal. A word that appears as NO alternative
is a REAL RESERVATION, and enforcing it is the only thing standing between a
grammar and a document nobody can parse.

``sibling_alternatives`` below computes that set wherever the grammar shows it.
For ``FieldName`` it cannot: the rule that gives its lookaheads their purpose is
``SDocNodeField``, which lives in the DOCUMENT grammar and is not in the recipe
this surface walks — the ``.sgra`` grammar only ever enters ``FieldName`` after
the literal ``'  - TITLE: '``. So those two answers are recorded, per word and
with the reason, in ``LINE_ANCHORED_DENIALS``. An anchored denial that is
neither computable nor registered is an error.

Enforcement needs no regex, which is the point: a denial lifted out of a
pattern is a list checked in Nix, and that is what makes it expressible at all
when POSIX extended regex has no lookaheads. An enforced word joins ``deny``
and rides the ``addCheck`` branch ``patternType`` already carries; an
unenforced one stays in ``denyAtLineStart``, recorded and inert.
"""

from __future__ import annotations

from typing import Any, Sequence

import emit_nix
from emit_nix import Raw
from shape import (
    ExtractionError,
    alternative_key,
    attributes_of,
    key_of,
)

# Names bound in the generated file's `let`. A rule that collided with one would
# be shadowed inside `types`, so the collision is asserted away rather than
# hoped about.
PREAMBLE_NAMES = ("t", "mkOption", "patternType")

# Characters an ERE gives a special meaning, for escaping a literal into one.
_ERE_SPECIAL = set(r".^$*+?()[]{}|\\")

# Escapes whose meaning is identical in both dialects and can be passed through.
_ERE_SAFE_ESCAPES = set(r".^$*+?()[]{}|\\")

# Python shorthand classes, spelled as POSIX bracket expressions. The values are
# the *inside* of a bracket expression, so they compose in both positions.
_SHORTHAND_INSIDE = {
    "d": "0-9",
    "w": "0-9A-Za-z_",
    "s": "[:space:]",
}
_SHORTHAND_NEGATED = {"D": "d", "W": "w", "S": "s"}

# Escapes that stand for a control character. ERE has no such escape, so the
# character itself is emitted.
_CONTROL_ESCAPES = {"n": "\n", "r": "\r", "t": "\t"}

# The rewrite names the two line-anchored outcomes carry.
POSITIONAL_REWRITE = "line-anchored-lookahead-is-positional"
RESERVED_REWRITE = "line-anchored-lookahead-is-reserved"

# The answer for every `^`-anchored denial whose sibling alternatives this
# recipe does not show, as (denier, word) -> (enforce?, why). Hand-written, and
# deliberately so: it is a human decision about a rule that is not in front of
# us, and an unregistered one is an error rather than a guess in either
# direction. `sibling_alternatives` is consulted FIRST — a register entry only
# ever answers a question the grammar could not.
LINE_ANCHORED_DENIALS: dict[tuple[str, str], tuple[bool, str]] = {
    ("FieldName", "UID"): (
        False,
        "UID appears as its own literal alternative in SDocNodeField, so the "
        "lookahead is a backtracking guard rather than a reservation. A field "
        "titled UID is legal, and docs/sdoc/grammar.sgra declares one five "
        "times; enforcing this would reject the repository's own grammar.",
    ),
    ("FieldName", "RELATIONS"): (
        True,
        "RELATIONS appears as no alternative of SDocNodeField -- it is the "
        "header of the relations block. MEASURED: a grammar declaring a field "
        "titled RELATIONS exports clean with exit 0, and every document that "
        "USES that field then fails to parse, because the parser reaches "
        "RELATIONS: expecting the block header. StrictDoc validates nothing "
        "here, so this type is the only place the mistake can be caught.",
    ),
}


# ─── the ERE dialect compiler ────────────────────────────────────────────────


def _capture_group_sources(pattern: str) -> dict[int, str]:
    """Map each capturing group's number to its inner source text."""
    sources: dict[int, str] = {}
    stack: list[tuple[int, int]] = []
    number = 0
    index = 0
    in_class = False
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            index += 2
            continue
        if in_class:
            if char == "]":
                in_class = False
            index += 1
            continue
        if char == "[":
            in_class = True
            index += 1
            continue
        if char == "(":
            if pattern[index + 1 : index + 2] == "?":
                stack.append((-1, index))
            else:
                number += 1
                stack.append((number, index + 1))
            index += 1
            continue
        if char == ")":
            if not stack:
                raise ExtractionError(f"unbalanced ')' in pattern {pattern!r}")
            group_number, start = stack.pop()
            if group_number > 0:
                sources[group_number] = pattern[start:index]
            index += 1
            continue
        index += 1
    if stack:
        raise ExtractionError(f"unbalanced '(' in pattern {pattern!r}")
    return sources


def _single_literal_of(group_source: str) -> str:
    """The one character a group can match, or an error.

    Only ever asked of a backreference target. ``(["])`` is the whole reason
    this exists: it is a one-member bracket expression, so the reference is an
    exact literal and substituting it changes nothing.
    """
    if len(group_source) == 1 and group_source not in _ERE_SPECIAL:
        return group_source
    if (
        len(group_source) == 3
        and group_source[0] == "["
        and group_source[2] == "]"
        and group_source[1] not in "^]"
    ):
        return group_source[1]
    raise ExtractionError(
        f"backreference target {group_source!r} is not a single literal; no named "
        "rewrite claims it"
    )


def _hoist_lookaheads(pattern: str) -> tuple[str, list[str], bool]:
    """Split leading ``(?!…)`` groups off the front of ``pattern``."""
    denials: list[str] = []
    hoisted = False
    while pattern.startswith("(?!"):
        # depth starts at 1: the `(` of `(?!` is already consumed.
        depth = 1
        index = 3
        in_class = False
        end = -1
        while index < len(pattern):
            char = pattern[index]
            if char == "\\":
                index += 2
                continue
            if in_class:
                if char == "]":
                    in_class = False
            elif char == "[":
                in_class = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    end = index
                    break
            index += 1
        if end < 0:
            raise ExtractionError(f"unterminated lookahead in pattern {pattern!r}")
        denials.append(pattern[3:end])
        pattern = pattern[end + 1 :]
        hoisted = True
    if hoisted and _has_top_level_alternation(pattern):
        raise ExtractionError(
            "a hoisted lookahead in front of a top-level alternation would change "
            f"which branch it guards: {pattern!r}"
        )
    if "(?" in pattern:
        raise ExtractionError(
            f"pattern {pattern!r} carries an inline group Nix's regex engine "
            "cannot express, and it is not at the front to be hoisted"
        )
    return pattern, denials, hoisted


def _has_top_level_alternation(pattern: str) -> bool:
    depth = 0
    in_class = False
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            index += 2
            continue
        if in_class:
            if char == "]":
                in_class = False
        elif char == "[":
            in_class = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "|" and depth == 0:
            return True
        index += 1
    return False


def _rewrite_body(pattern: str, groups: dict[int, str], rewrites: set[str]) -> str:
    """Rewrite one lookahead-free pattern into POSIX ERE."""
    out: list[str] = []
    index = 0
    in_class = False
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            escape = pattern[index + 1 : index + 2]
            if not escape:
                raise ExtractionError(f"trailing backslash in pattern {pattern!r}")
            index += 2
            if escape in _CONTROL_ESCAPES:
                out.append(_CONTROL_ESCAPES[escape])
                rewrites.add("control-escape-to-literal")
                continue
            if escape in _SHORTHAND_INSIDE:
                inside = _SHORTHAND_INSIDE[escape]
                out.append(inside if in_class else f"[{inside}]")
                rewrites.add("shorthand-class-to-posix")
                continue
            if escape in _SHORTHAND_NEGATED:
                if in_class:
                    raise ExtractionError(
                        f"negated shorthand \\{escape} inside a bracket expression "
                        f"has no POSIX spelling: {pattern!r}"
                    )
                out.append(f"[^{_SHORTHAND_INSIDE[_SHORTHAND_NEGATED[escape]]}]")
                rewrites.add("shorthand-class-to-posix")
                continue
            if escape == "-":
                if not in_class:
                    out.append("-")
                    continue
                if pattern[index : index + 1] != "]":
                    raise ExtractionError(
                        "an escaped hyphen that is not last in its bracket "
                        f"expression would become a range: {pattern!r}"
                    )
                out.append("-")
                rewrites.add("bracket-escaped-hyphen")
                continue
            if escape.isdigit() and escape != "0":
                if in_class:
                    raise ExtractionError(
                        f"backreference inside a bracket expression: {pattern!r}"
                    )
                target = groups.get(int(escape))
                if target is None:
                    raise ExtractionError(
                        f"backreference \\{escape} has no group in {pattern!r}"
                    )
                out.append(_single_literal_of(target))
                rewrites.add("backreference-to-literal")
                continue
            if escape == "/":
                out.append("/")
                continue
            if escape in _ERE_SAFE_ESCAPES:
                if in_class:
                    raise ExtractionError(
                        "POSIX reads a backslash inside a bracket expression as a "
                        f"literal backslash, so \\{escape} would widen: {pattern!r}"
                    )
                out.append("\\" + escape)
                continue
            raise ExtractionError(
                f"no named rewrite claims the escape \\{escape} in {pattern!r}"
            )
        if in_class:
            if char == "]":
                in_class = False
            out.append(char)
            index += 1
            continue
        if char == "[":
            in_class = True
            out.append(char)
            index += 1
            # A `]` or `^]` immediately inside is a literal `]`, not the end.
            if pattern[index : index + 1] == "^":
                out.append("^")
                index += 1
            if pattern[index : index + 1] == "]":
                out.append("]")
                index += 1
            continue
        out.append(char)
        index += 1
    if in_class:
        raise ExtractionError(f"unterminated bracket expression in {pattern!r}")
    return "".join(out)


# ─── which line-anchored denials are enforced ────────────────────────────────


def _branch_head_rule(head: dict) -> str | None:
    """The rule a branch leads with, if it leads with one."""
    if head["kind"] == "rule":
        return head["name"]
    if head["kind"] == "assign" and head["value"]["kind"] == "rule":
        return head["value"]["name"]
    return None


def _choices(items: Sequence[dict]):
    """Every ordered choice anywhere under ``items``."""
    for item in items:
        if item["kind"] == "choice":
            yield item
            for branch in item["branches"]:
                yield from _choices(branch)
        elif "items" in item:
            yield from _choices(item["items"])


def sibling_alternatives(rule_name: str, rules: dict) -> set[str] | None:
    """The literal keys that stand where ``rule_name`` stands, or ``None``.

    A reference is POSITION-DISCRIMINATED when it is the FIRST item of a branch
    of an ordered choice: what appears at that position is then chosen between
    that branch's head and the other branches' heads, which is exactly the
    question a ``^``-anchored lookahead answers. A reference preceded by a
    literal is not — the literal has already fixed the position, and the choice
    is discriminating something else. ``FieldName`` is only ever reached after
    ``'  - TITLE: '``, which is why this returns ``None`` for it.

    ``None`` also covers a position whose siblings cannot all be read as literal
    keys: a set that could not be enumerated is not a set a word can be shown to
    be absent from.
    """
    found: set[str] = set()
    seen = False
    for rule in rules.values():
        for choice in _choices(rule["items"]):
            heads = [branch[0] for branch in choice["branches"] if branch]
            if len(heads) != len(choice["branches"]):
                continue
            if not any(_branch_head_rule(head) == rule_name for head in heads):
                continue
            keys = set()
            for head in heads:
                if _branch_head_rule(head) == rule_name:
                    continue
                key = key_of(head["text"]) if head["kind"] == "literal" else None
                if key is None:
                    return None
                keys.add(key)
            seen = True
            found |= keys
    return found if seen else None


def _split_line_anchored(
    owner: str, words: Sequence[str], rules: dict
) -> tuple[list[str], list[str]]:
    """Split anchored denials into (enforced, recorded-only)."""
    alternatives = sibling_alternatives(owner, rules) if owner in rules else None
    enforced: list[str] = []
    recorded: list[str] = []
    for word in words:
        if alternatives is not None:
            (enforced if word not in alternatives else recorded).append(word)
            continue
        decision = LINE_ANCHORED_DENIALS.get((owner, word))
        if decision is None:
            raise ExtractionError(
                f"{owner}: the `^`-anchored denial of {word!r} has no sibling "
                f"alternatives in this recipe to be decided against, and no entry "
                f"in LINE_ANCHORED_DENIALS.\n"
                f"  Decide it: a word that is an alternative of the rule that "
                f"denies it is a backtracking guard and must NOT be enforced; a "
                f"word that is an alternative of nothing is a reservation and "
                f"should be. Record the answer with the reason."
            )
        (enforced if decision[0] else recorded).append(word)
    return enforced, recorded


# ─── pattern records ─────────────────────────────────────────────────────────


def compile_pattern(
    source: str, owner: str, rules: dict, *, literals: list[str] | None = None
) -> dict:
    """Compile one upstream pattern into the record the Nix surface carries."""
    groups = _capture_group_sources(source)
    body, raw_denials, hoisted = _hoist_lookaheads(source)
    rewrites: set[str] = set()
    if hoisted:
        rewrites.add("hoist-negative-lookahead")
    denials = []
    anchored = []
    for denial in raw_denials:
        # A `^`-anchored lookahead constrains WHERE the rule may be entered as
        # well as what the value may be, and whether it is also a reservation is
        # decided below rather than assumed either way.
        if denial.startswith("^"):
            anchored.append(
                _rewrite_body(denial[1:], _capture_group_sources(denial[1:]), rewrites)
            )
            continue
        denials.append(_rewrite_body(denial, _capture_group_sources(denial), rewrites))
    enforced, recorded = _split_line_anchored(owner, anchored, rules)
    if enforced:
        rewrites.add(RESERVED_REWRITE)
    if recorded:
        rewrites.add(POSITIONAL_REWRITE)
    record: dict[str, Any] = {
        "source": source,
        "ere": _rewrite_body(body, groups, rewrites),
        "deny": denials + enforced,
        "denyAtLineStart": recorded,
        "rewrites": sorted(rewrites),
    }
    if literals is not None:
        record["literals"] = literals
    return record


def literal_pattern(text: str) -> dict:
    """The pattern record for a production that admits exactly one literal."""
    return {
        "source": text,
        "ere": "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text),
        "deny": [],
        "denyAtLineStart": [],
        "rewrites": ["literal-to-pattern"],
        "literals": [text],
    }


def literal_set_pattern(texts: list[str]) -> dict:
    """The pattern record for an ``OrderedChoice`` of ``StrMatch`` children.

    This is the first of the two shapes a literal set arrives in. The second —
    an inline regex alternation such as ``/(True|False)/`` — needs no special
    handling here: it is already a pattern. Both end up as a checkable string
    type, and both keep their literal set for the converters to enum.
    """
    branches = [
        "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text) for text in texts
    ]
    return {
        "source": "|".join(texts),
        "ere": "(" + "|".join(branches) + ")",
        "deny": [],
        "denyAtLineStart": [],
        "rewrites": ["ordered-choice-to-alternation"],
        "literals": list(texts),
    }


def _literals_of(name: str, items: Sequence[dict]) -> list[str]:
    if len(items) == 1 and items[0]["kind"] == "choice":
        literals = []
        for branch in items[0]["branches"]:
            if len(branch) != 1 or branch[0]["kind"] != "literal":
                raise ExtractionError(f"{name}: branch is not a bare literal")
            literals.append(branch[0]["text"])
        return literals
    raise ExtractionError(f"{name}: not an ordered choice of literals")


def match_pattern_of(name: str, items: Sequence[dict], rules: dict) -> dict:
    """The pattern record for a textx ``match`` rule, or an alias to another."""
    # `!ReservedKeyword /…/` — a lookahead over a named literal set.
    if (
        len(items) == 2
        and items[0]["kind"] == "not"
        and items[1]["kind"] == "regex"
        and len(items[0]["items"]) == 1
        and items[0]["items"][0]["kind"] == "rule"
    ):
        denied_name = items[0]["items"][0]["name"]
        literals = _literals_of(denied_name, rules[denied_name]["items"])
        record = compile_pattern(items[1]["pattern"], name, rules)
        record["deny"] = record["deny"] + [
            "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text)
            for text in literals
        ]
        record["rewrites"] = sorted(set(record["rewrites"]) | {"negative-lookahead-rule"})
        record["denyRule"] = denied_name
        return record

    if len(items) == 1:
        only = items[0]
        if only["kind"] == "regex":
            return compile_pattern(only["pattern"], name, rules)
        if only["kind"] == "literal":
            return literal_pattern(only["text"])
        if only["kind"] == "rule":
            return {"alias": only["name"]}
        if only["kind"] == "choice":
            return literal_set_pattern(_literals_of(name, items))
    raise ExtractionError(f"{name}: no handling for this match-rule production shape")


# ─── the typed surface ───────────────────────────────────────────────────────

PATTERN_TYPE_SRC = """p:
    # `p.ere` is p.source in the dialect `builtins.match` speaks; `p.deny`
    # carries the negative lookahead groups that dialect cannot spell, checked
    # as prefix rejections instead. `.*` is deliberate: Nix's `.` matches a
    # newline, so a denied prefix is caught wherever the rest of the string
    # goes.
    #
    # A `^`-anchored lookahead is in `p.deny` too when the word it denies is an
    # alternative of nothing — a real reservation rather than a backtracking
    # guard. `p.denyAtLineStart` is the other half of that split: recorded,
    # deliberately inert, and never a constraint on the value alone.
    if p.deny == []
    then t.strMatching p.ere
    else
      t.addCheck (t.strMatching p.ere)
      (s: !(lib.any (d: builtins.match "(${d}).*" s != null) p.deny))"""

_ALTERNATIVE_DESCRIPTION = (
    "`{alt}` — one alternative of the `{name}` union. attrTag, not a record "
    "with optional extras: the module system's addCheck predicate never fires "
    "inside a submodule, so a structural union is the only one with no hole in "
    "it."
)


def _paren(src: str) -> str:
    """Parenthesize an argument, unless it is a single atom.

    `t.nullOr (t.bool)` is a statix warning ([04] parenthesized single value)
    and `t.nullOr t.bool` is the same type, so a converted node must not carry
    the parentheses the pattern record it replaced needed.
    """
    return src if not any(c.isspace() for c in src) else f"({src})"


class Surface:
    """Builds the `types` block from faithful's raw rule records.

    ``classify`` is called for every node, as ``classify(path, node)``, and
    returns either replacement Nix source for that node or ``None`` to keep what
    this module built. That is the seam the converters plug into: this module
    knows how to spell a `.sgra` rule as a Nix type, and nothing about which
    types are better than which.
    """

    def __init__(self, rules: dict, classify) -> None:
        clash = sorted(set(rules) & set(PREAMBLE_NAMES))
        if clash:
            raise ExtractionError(f"rule names shadow the generated preamble: {clash}")
        self.rules = rules
        self.classify = classify

    def types(self) -> dict[str, Raw]:
        return {name: self.rule_type(name) for name in sorted(self.rules)}

    ## one rule ---------------------------------------------------------------

    def rule_type(self, name: str) -> Raw:
        rule = self.rules[name]
        path = f"types.{name}"

        if rule["txType"] == "abstract":
            return Raw(self._abstract(path, name, rule))

        if rule["txType"] == "match":
            record = match_pattern_of(name, rule["items"], self.rules)
            if "alias" in record:
                target = record["alias"]
                if target not in self.rules:
                    raise ExtractionError(f"{name}: aliases unknown rule {target}")
                replaced = self.classify(path, {"kind": "alias", "target": target})
                return Raw(target if replaced is None else replaced)
            return Raw(self._pattern(path, record))

        return Raw(self._submodule(path, name, rule))

    def _abstract(self, path: str, name: str, rule: dict) -> str:
        replaced = self.classify(path, {"kind": "attrTag"})
        if replaced is not None:
            return replaced
        options = {}
        for alternative in rule["alternatives"]:
            key, target = alternative["key"], alternative["rule"]
            if key != alternative_key(name, target):
                raise ExtractionError(
                    f"{path}: alternative key {key!r} is not the one "
                    f"{target!r} produces"
                )
            options[key] = emit_nix.render_option(
                Raw(self._reference(f"{path}.{key}.type", target)),
                description=_ALTERNATIVE_DESCRIPTION.format(alt=target, name=name),
                indent=3,
            )
        return "t.attrTag " + emit_nix.render_attrs(options, 2)

    def _submodule(self, path: str, name: str, rule: dict) -> str:
        replaced = self.classify(path, {"kind": "submodule"})
        if replaced is not None:
            return replaced
        attributes = attributes_of(name, rule["items"])
        if not attributes:
            raise ExtractionError(f"{name}: a common rule with no attributes")
        options = {
            record["option"]: self._option(path, name, record) for record in attributes
        }
        return "t.submodule " + emit_nix.render_attrs(
            {"options": Raw(emit_nix.render_attrs(options, 3))}, 2
        )

    ## one option -------------------------------------------------------------

    def _option(self, path: str, name: str, record: dict) -> Raw:
        inner = self._wrapped(f"{path}.options.{record['option']}.type", name, record)

        where = (
            f"`{record['key']}` of `{name}`"
            if record["key"]
            else f"an unlabelled production of `{name}`"
        )
        description = (
            f"{where}. "
            f"{'Optional' if record['optional'] else 'Mandatory'}; "
            f"{'a list' if record['list'] else 'a single value'}. "
            f"Upstream textx attribute `{record['attr']}`."
        )

        default: Any = emit_nix._UNSET  # noqa: SLF001 - the module's own sentinel
        if record["optional"]:
            default = None
        elif record["value"]["kind"] == "literal" and not record["list"]:
            # A production that admits exactly one string is not a choice, so the
            # only possible value is also the only sensible default.
            default = record["value"]["text"]
        return emit_nix.render_option(
            Raw(inner), default=default, description=description, indent=3
        )

    def _wrapped(self, path: str, name: str, record: dict) -> str:
        if not record["optional"]:
            return self._listed(path, name, record)
        replaced = self.classify(path, {"kind": "nullOr"})
        if replaced is not None:
            return replaced
        return "t.nullOr " + _paren(self._listed(f"{path}.nullOr", name, record))

    def _listed(self, path: str, name: str, record: dict) -> str:
        if not record["list"]:
            return self._value(path, name, record)
        replaced = self.classify(
            path,
            {
                "kind": "list",
                "rule": name,
                "option": record["option"],
                "multiplicities": record["multiplicities"],
            },
        )
        if replaced is not None:
            return replaced
        wrapper = "nonEmptyListOf" if record["nonEmpty"] else "listOf"
        inner = self._value(f"{path}.{wrapper}", name, record)
        return f"t.{wrapper} " + _paren(inner)

    def _value(self, path: str, name: str, record: dict) -> str:
        value = record["value"]
        owner = f"{name}.{record['option']}"
        if value["kind"] == "rule":
            return self._reference(path, value["name"])
        if value["kind"] == "pattern":
            pattern = compile_pattern(value["pattern"], owner, self.rules)
        elif value["kind"] == "literal":
            pattern = literal_pattern(value["text"])
        elif value["kind"] == "literals":
            pattern = literal_set_pattern(value["literals"])
        else:
            raise ExtractionError(f"no Nix type for assignment value {value['kind']}")
        return self._pattern(path, pattern)

    ## leaves -----------------------------------------------------------------

    def _reference(self, path: str, target: str) -> str:
        if target not in self.rules:
            raise ExtractionError(
                f"{path}: reference to `{target}`, which is not a rule of this surface"
            )
        replaced = self.classify(path, {"kind": "ruleReference", "target": target})
        return target if replaced is None else replaced

    def _pattern(self, path: str, record: dict) -> str:
        replaced = self.classify(path, {"kind": "pattern", "record": record})
        if replaced is not None:
            return replaced
        return "patternType " + emit_nix.render_attrs(record, 3)
