# Inheritance and implicit scope

> **Last verified:** 2026-10-23 — N2 extends the lexical resolver with inherited
> declarations, literal `with` members and generated runtime globals.

A binding introduces a name; an occurrence uses it. An implicit scope supplies
names from a `with` environment expression. A candidate is a supported target
for an occurrence. A definite target is established only when no uncertain inner
environment can replace it. This layer extends
[explicit lexical scope](lexical-scope.md) without evaluating Nix values or
adding database tables.

## Inheritance

`Inheritance.qll` contributes through `LexicalScopeProvider`. Both `inherit x;`
and `inherit (expr) x;` introduce static declarations when their containing set
or `let` has an applicable lexical frame. Ordinary sets do not expose inherited
names to sibling values. Inherited declarations participate in the existing
nearest-frame selection and duplicate-binder checks. Known inherited names
suppress same-frame computed-key uncertainty just as ordinary static
declarations do. A frame excluded for a bare inherited occurrence contributes no
uncertainty to that occurrence; unknown membership in other enclosing frames
still applies.

Bare `inherit x;` also makes its name token an occurrence. Lookup excludes its
own declaration frame, so `let x=11; in (rec { inherit x; }).x` copies the outer
`x` rather than referring to itself. The token retains both roles and its
authenticated source location. Plain quoted inherited names use their static
spelling; computed names supply no invented declaration.

In `inherit (expr) x;`, `x` is a selected attribute key, not a variable
occurrence. Variable uses inside `expr` resolve normally, including through the
containing recursive frame. The selected attribute's value is outside this
name-resolution layer.

## Implicit candidates

`ImplicitScopes.qll` supplies fallback candidates through
`ImplicitScopeProvider`. Explicit lexical names always win, regardless of how
deeply a `with` occurs. This includes compatible runtime globals in the
outermost explicit frame. A `with` environment expression is outside its own
implicit scope; only its body receives those names.

For a literal set, static first path components and inherited names establish
membership. Parentheses preserve this recognition. Dotted attributes contribute
their first component as the available name. Repeated contributions choose the
earliest name token as their canonical target. The layer identifies membership,
rather than evaluating member values or proving that the environment evaluates
successfully.

An environment that is not a literal set, or a literal set with a computed first
component, may supply any name. No function, variable, import or computed key is
evaluated to discover members. Such unknown membership is a lookup boundary, not
an enumerated binding for every spelling.

Lookup considers `with` environments from inner to outer. The nearest known
member shadows farther known members. If an unknown environment is nearer, the
retained outer member is only a may candidate; it cannot become definite. With
no supported known member, both target relations are empty. A known member in a
literal environment wins over that same environment's unknown membership.

Source-backed implicit candidates retain their member token's location through
the optional `ImplicitScopeProvider.getDeclaration` method. Its default returns
no declaration, preserving providers whose identities have no location.
`NameBindings.ql` therefore reports a located definite `with` target when one
exists. Its zero target coordinates also cover unavailable resolution and
definite identities without a source location.

## Runtime globals and compatibility

`RuntimeGlobals` connects [generated builtin identities](builtin-models.md) to
N1's `OutermostBuiltinFrameProvider`. Its provider identity is distinct from the
synthetic provider used by the lexical tests, preventing their runtime, model
and symbol facts from combining.

The run's model fingerprint must equal the installed model fingerprint before a
generated global becomes a definite target. Missing or mismatched fingerprints
leave that resolution unavailable. Local declarations still shadow globals. The
raw `globalBindingIdentity` inventory reserves recognized global spellings so an
incompatible global cannot fall through to `with`; inventory membership alone
supplies no compatible-resolution evidence. Runtime identities have no
declaration token or source location.

## Verification and maintenance

`checks.x86_64-linux.codeql-nix-anchors` runs the new tests through the existing
F3 owner check. Frozen `NameBindings.ql` and `Resolution.ql` rows under
`ql/test/implicit-scope/` cover inheritance, lexical precedence, known and
unknown environments, locations, and negative controls.
`checks/fixtures/implicit-scope/test_implicit.py` independently evaluates the
source expressions with real Nix, changes unknown membership to reveal capture,
and checks a safe outer rename and an inheritance sentinel.

The same check runs `ql/test/implicit-builtins/` through the installed extractor
for compatible globals, then queries an incompatible model and checks
absent-model rows through the syntax fixture. Nix sentinel values independently
verify global precedence and local shadowing. Synthetic provider tests remain
separate from production identities.

When changing these rules, update independent rows and Nix witnesses together.
Preserve authenticated nodes, inherited binder/use roles,
lexical-before-implicit precedence, must within may, and invalid versus
unavailable. The unknown computed-frame limitations documented in the lexical
contract still apply; this slice makes no general soundness claim for arbitrary
Nix evaluation. Import resolution, value evaluation and builtin-model generation
remain separate responsibilities. Format changed files and run the owner check
through CI.
