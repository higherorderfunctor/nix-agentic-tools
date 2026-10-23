# Minimal public syntax

> **Last verified:** 2026-10-23 — five syntax forms reuse the authenticated
> source bridge and the owner anchor check.

CodeQL stores extracted facts; QL is its query language. An abstract syntax tree
(AST) represents the grammatical parts of source code. `ql/lib/nix/Ast.qll`
gives queries five public forms: `AttrSet`, `Binding`, `FunctionExpr`,
`Identifier` and `LetExpr`. A binding assigns an expression to an attribute
path. These forms let a later query find option assignments inside a module
function and its returned set.

Raw nodes are parser-generated syntax records. Authentication checks admitted
source bytes against their declared digests. Only `nix/internal/RawBridge.qll`
imports generated syntax for this interface. It reuses the
[source authentication and anchor mapping](source-identity.md), rather than
adding a parser or database tables. An anchor identifies a source node by file,
byte range, grammar kind and child path. Public nodes require an authenticated
anchor with exactly one matching raw node; duplicate raw extraction therefore
exposes no public nodes. Locations and relative paths come through that same
mapping. The existing library assembly copies the whole `ql/lib/` tree into the
installed pack.

A candidate is a source binding that may later be associated with evaluation
evidence. Distinct bindings remain separate candidates even when their attribute
paths match. A candidate requires a uniquely mapped, nonempty value expression
and a wholly literal path. Path segments retain their order: `demo.answer` has
two, while `"demo.answer"` has one. Identifier segments and plain quoted strings
are supported; interpolation or unsupported string components reject the whole
candidate. A recovered missing value is excluded while a later intact binding
can remain visible.

Binding values and function or let bodies return only the five supported forms.
A variable expression returns its identifier token. Function parameters
currently expose only identifier parameters. These relations describe syntax;
they do not resolve names or identify which expression produced an evaluated
value.

`checks.x86_64-linux.codeql-nix-anchors` runs the `Ast` and `Candidates` queries
in `ql/test/step0/` through the existing authenticated syntax producer.
Independent expected rows check quoted-dot segments, repeated literal paths,
malformed-input recovery and refusal of dynamic paths. A separate `Ambiguous`
run duplicates raw extraction and requires zero public candidate counts.

After the live `Ast` results match the expected rows,
`checks/fixtures/step0/reconstruct.py` reconstructs all five forms from those
rows. It compares the result with independent `nix-instantiate --parse` output
for the original fixture. Removing body or segment rows must fail
reconstruction. Source bytes supply only the independent expected parse;
replaying archived source cannot satisfy this check.

When adding a form, extend the private bridge and public class together, then
add independent relation and reconstruction expectations to the owner check.
Preserve unique anchor mapping, whole-path refusal and the distinction between
source candidates and evaluation evidence. Format changed files and run
`checks.x86_64-linux.codeql-nix-anchors`; do not edit generated syntax by hand.
