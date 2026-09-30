"""Tree-sitter-rust walking helpers shared by the Rust config-key extractors.

Every fact these helpers return is read from a typed syntax-tree node: a
node's kind, its named fields, its children, or the token children of a macro
token tree. None of them runs a regular expression over source text. The
only text they decode is the content of a string or integer literal NODE,
and the escape sequences inside a string literal are themselves child nodes.

Test code is decided here once, for every extractor: an item preceded by (or,
for a match arm, carrying) `#[cfg(test)]` or `#[test]`, plus the test-only
paths below. Any other `cfg` that mentions `test` cannot be classified and is
reported through `unclassified_test_attributes`, so the caller can fail closed.
"""

from pathlib import Path

import tree_sitter_rust
from tree_sitter import Language, Parser

PARSER = Parser(Language(tree_sitter_rust.language()))

ATTRIBUTE_SIBLINGS = {"attribute_item", "line_comment", "block_comment"}
STRING_KINDS = {"string_literal", "raw_string_literal"}
INTEGER_SUFFIXES = ("i8", "i16", "i32", "i64", "i128", "isize",
                    "u8", "u16", "u32", "u64", "u128", "usize")
SIMPLE_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "0": "\0",
                  "'": "'", '"': '"'}


def text(node):
    return node.text.decode()


def is_test_path(rel):
    return "/tests/" in rel or rel.endswith("testing.rs") or "/benches/" in rel


# ── Attributes ────────────────────────────────────────────────────────
def attribute_parts(item):
    """(path, argument token tree or None) of an `attribute_item`."""
    attr = next((c for c in item.named_children if c.type == "attribute"), None)
    if attr is None:
        return None, None
    path = attr.named_children[0] if attr.named_children else None
    return (text(path) if path is not None else None), attr.child_by_field_name("arguments")


def token_leaves(node):
    """Every non-token-tree token under a token tree, in order."""
    for child in node.children:
        if child.type == "token_tree":
            yield from token_leaves(child)
        else:
            yield child


def test_attribute(item):
    """'test' for #[test] / #[cfg(test)], 'other' for any other cfg naming
    `test`, None otherwise."""
    path, args = attribute_parts(item)
    if path == "test" and args is None:
        return "test"
    if path != "cfg" or args is None:
        return None
    inner = [c for c in args.children if c.type not in ("(", ")")]
    if len(inner) == 1 and inner[0].type == "identifier" and text(inner[0]) == "test":
        return "test"
    if any(leaf.type == "identifier" and text(leaf) == "test" for leaf in token_leaves(args)):
        return "other"
    return None


def leading_attributes(node):
    """The attribute items attached to `node`: its contiguous preceding
    attribute/comment siblings, plus attributes it carries as leading
    children (match arms and struct fields hold them inside)."""
    out = []
    sibling = node.prev_sibling
    while sibling is not None and sibling.type in ATTRIBUTE_SIBLINGS:
        if sibling.type == "attribute_item":
            out.append(sibling)
        sibling = sibling.prev_sibling
    for child in node.children:
        if child.type == "attribute_item":
            out.append(child)
        elif child.type not in ATTRIBUTE_SIBLINGS:
            break
    return out


def is_test_item(node):
    return any(test_attribute(a) == "test" for a in leading_attributes(node))


# ── Literals ──────────────────────────────────────────────────────────
def decode_escape(seq):
    body = seq[1:]
    if body[:1] in SIMPLE_ESCAPES and len(body) == 1:
        return SIMPLE_ESCAPES[body]
    if body.startswith("x"):
        return chr(int(body[1:], 16))
    if body.startswith("u{"):
        return chr(int(body[2:-1].replace("_", ""), 16))
    if body[:1] == "\n":  # a line continuation drops the newline and indent
        return ""
    raise ValueError(f"unknown escape sequence {seq!r}")


def string_value(node):
    """The value of a string or raw string literal node, else None."""
    if node.type not in STRING_KINDS:
        return None
    parts = []
    for child in node.named_children:
        if child.type == "string_content":
            parts.append(text(child))
        elif child.type == "escape_sequence":
            parts.append(decode_escape(text(child)))
    return "".join(parts)


def integer_value(node):
    literal = text(node).replace("_", "")
    for suffix in INTEGER_SUFFIXES:
        if literal.endswith(suffix) and not literal.startswith(("0x", "0X")):
            literal = literal[: -len(suffix)]
            break
    return int(literal, 0)


def literal_value(node):
    """(ok, value) for a bool, integer (optionally negated) or string
    literal node."""
    if node is None:
        return False, None
    if node.type == "boolean_literal":
        return True, text(node) == "true"
    if node.type == "integer_literal":
        return True, integer_value(node)
    if node.type == "unary_expression" and node.child_count == 2 and node.children[0].type == "-" \
            and node.children[1].type == "integer_literal":
        return True, -integer_value(node.children[1])
    if node.type in STRING_KINDS:
        return True, string_value(node)
    return False, None


# ── Expressions ───────────────────────────────────────────────────────
def unwrap(node):
    """Strip grouping that never changes which value an expression names:
    parentheses, `&` / `&mut`, and a trailing `?`."""
    while node is not None:
        if node.type == "parenthesized_expression" and node.named_child_count == 1:
            node = node.named_children[0]
        elif node.type == "reference_expression":
            node = node.child_by_field_name("value")
        elif node.type == "try_expression" and node.named_child_count == 1:
            node = node.named_children[0]
        else:
            return node
    return node


def call_args(call):
    args = call.child_by_field_name("arguments")
    return [] if args is None else [c for c in args.named_children if c.type not in ATTRIBUTE_SIBLINGS]


def method_call(call):
    """(receiver, method name, turbofish type node or None) when `call` is a
    `recv.name(..)` / `recv.name::<T>(..)` call, else None."""
    if call.type != "call_expression":
        return None
    function = call.child_by_field_name("function")
    turbofish = None
    if function.type == "generic_function":
        turbofish = function.child_by_field_name("type_arguments")
        function = function.child_by_field_name("function")
    if function.type != "field_expression":
        return None
    field = function.child_by_field_name("field")
    return function.child_by_field_name("value"), text(field), turbofish


def path_call(call):
    """(path text or None, name) for `a::b::name(..)` / `name(..)` calls."""
    if call.type != "call_expression":
        return None
    function = call.child_by_field_name("function")
    if function.type == "generic_function":
        function = function.child_by_field_name("function")
    if function.type == "identifier":
        return None, text(function)
    if function.type == "scoped_identifier":
        path = function.child_by_field_name("path")
        return (text(path) if path is not None else None), text(function.child_by_field_name("name"))
    return None


def callee_name(call):
    """The final segment of whatever a call expression calls."""
    as_method = method_call(call)
    if as_method:
        return as_method[1]
    as_path = path_call(call)
    return as_path[1] if as_path else None


def split_token_tree(tree):
    """A macro token tree's top-level arguments, split at its own `,`
    tokens: a list of token lists. Commas inside nested token trees (a
    call's own arguments) and inside string literals are never tokens at
    this level, so they cannot split an argument."""
    groups, current = [], []
    for child in tree.children[1:-1]:
        if child.type == ",":
            groups.append(current)
            current = []
        elif child.type not in ATTRIBUTE_SIBLINGS:
            current.append(child)
    if current:
        groups.append(current)
    return groups


def macro_parts(node):
    """(macro name, token tree) of a macro invocation, else None."""
    if node is None or node.type != "macro_invocation":
        return None
    name = node.child_by_field_name("macro")
    tree = next((c for c in node.children if c.type == "token_tree"), None)
    return (text(name).split("::")[-1] if name is not None else None), tree


def format_placeholders(template):
    """Split a decoded Rust format string into literal text and `{..}`
    placeholders, honouring `{{` and `}}` escapes: a list of strings and
    None (one None per placeholder)."""
    out, literal, i = [], [], 0
    while i < len(template):
        ch = template[i]
        if ch in "{}" and template[i:i + 2] in ("{{", "}}"):
            literal.append(ch)
            i += 2
        elif ch == "{":
            end = template.find("}", i)
            if end < 0:
                raise ValueError(f"unterminated placeholder in {template!r}")
            out.append("".join(literal))
            out.append(None)
            literal, i = [], end + 1
        else:
            literal.append(ch)
            i += 1
    out.append("".join(literal))
    return out


def type_identifiers(node):
    """Every type identifier named anywhere inside a type node."""
    if node is None:
        return set()
    found = {text(node)} if node.type == "type_identifier" else set()
    for child in node.children:
        found |= type_identifiers(child)
    return found


def option_inner(type_node):
    """The type argument of `Option<T>`, else the type itself."""
    if type_node is not None and type_node.type == "generic_type":
        base = type_node.child_by_field_name("type")
        args = type_node.child_by_field_name("type_arguments")
        if base is not None and text(base) == "Option" and args is not None and args.named_child_count == 1:
            return args.named_children[0]
    return type_node


def pattern_name(pattern):
    """The bound identifier of a plain `x` / `mut x` pattern, else None."""
    if pattern is None:
        return None
    if pattern.type == "mut_pattern":
        pattern = pattern.named_children[-1]
    return text(pattern) if pattern.type == "identifier" else None


def parameter_name(param):
    return pattern_name(param.child_by_field_name("pattern"))


def enclosing(node, kind):
    node = node.parent
    while node is not None and node.type != kind:
        node = node.parent
    return node


def descendants(node, kinds):
    """Nodes of the given kinds under `node` (inclusive), in source order."""
    stack = [node]
    out = []
    while stack:
        current = stack.pop()
        if current.type in kinds:
            out.append(current)
        stack.extend(reversed(current.children))
    return out


def doc_comment(item):
    """The `///` doc lines attached to an item, joined into one line of
    prose: attributes between the docs and the item are skipped, and a blank
    line ends the doc block once one has started."""
    lines, boundary = [], item.start_point[0]
    sibling = item.prev_sibling
    while sibling is not None:
        gap = sibling.end_point[0] < boundary - 1
        if lines and gap:
            break
        if sibling.type == "attribute_item":
            pass
        elif sibling.type == "line_comment" and sibling.child_by_field_name("outer") is not None:
            doc = sibling.child_by_field_name("doc")
            lines.append(text(doc) if doc is not None else "")
        else:
            break
        boundary = sibling.start_point[0]
        sibling = sibling.prev_sibling
    return " ".join(" ".join(reversed(lines)).split()) or None


# ── The source tree ───────────────────────────────────────────────────
class RustTree:
    """Every production `.rs` file under `root`, parsed once, with the nodes
    of each kind collected in source order."""

    def __init__(self, root):
        self.root = Path(root)
        self.by_kind = {}
        self.unclassified_test_attributes = []
        self.files = {}
        for path in sorted(self.root.rglob("*.rs")):
            rel = path.relative_to(self.root).as_posix()
            if is_test_path(rel):
                continue
            tree = PARSER.parse(path.read_bytes())
            self.files[rel] = tree
            self._collect(rel, tree.root_node)

    def _collect(self, rel, root):
        stack = [root]
        while stack:
            node = stack.pop()
            if node.is_named and is_test_item(node):
                continue
            if node.type == "attribute_item" and test_attribute(node) == "other":
                self.unclassified_test_attributes.append((rel, node))
            self.by_kind.setdefault(node.type, []).append((rel, node))
            stack.extend(reversed(node.children))

    def nodes(self, *kinds):
        """(file, node) pairs of the given kinds, in file and source order."""
        if len(kinds) == 1:
            return self.by_kind.get(kinds[0], [])
        merged = [pair for kind in kinds for pair in self.by_kind.get(kind, [])]
        return sorted(merged, key=lambda pair: (pair[0], pair[1].start_byte))


def line(node):
    return node.start_point[0] + 1
