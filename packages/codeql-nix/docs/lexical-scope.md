# Explicit lexical scope

> **Last verified:** 2026-10-23 — N1 resolves explicit names and reserves
> extension interfaces consumed by inheritance, implicit names and runtime
> primitives.

A binding introduces a name; an occurrence uses one. Lexical scope determines
which binding an occurrence can see from its position in source. A frame is one
group of names visible together. Resolution links an occurrence to a binding. QL
is CodeQL's query language; this meaning layer supplies resolution to
`NameBindings.ql` without evaluating Nix values.

The layer reuses [authenticated syntax](source-identity.md): authentication
checks source bytes against their recorded identity. Only the private bridge
reads generated syntax. `StaticScopes.qll` composes static attributes;
`Bindings.qll` exposes resolution. Static means an identifier or plain quoted
name, without computed parts.

`let` and recursive sets (`rec`) expose their static names simultaneously,
including inside their own values. Ordinary sets do not expose sibling names.
Functions expose identifier arguments, named arguments and the whole-argument
name written with `@`; argument defaults can see sibling arguments. An ellipsis
accepts extra arguments without inventing names. Dotted paths build nested sets;
a component becomes lexical only in an applicable recursive frame. Computed
attribute names introduce no lexical binding. Known path prefixes still
determine scope inside computed keys and their values.

Static definitions compose at the same attribute path, including nested paths
and parenthesized sets. A terminal value is a value other than a literal set.
Contributions conflict when either supplies a terminal value at their shared
path; disjoint members merge. Canonical identity is the single target chosen for
a merged name: its earliest name token in source. Conflicts yield invalid
resolution.

Source order also determines recursion: the first creation of each merged set
decides whether it is recursive. A dotted-path prefix first creates an ordinary
set. Later members share the resulting frame; a later `rec` cannot make an
ordinary first creation recursive. For example,
`let c=99; a=rec { b=c; }; a.c=2; in a.b` yields `2`, while placing `a.c=2`
first yields `99`. This prevents choosing a target from source nesting alone.

A recursive frame receiving a computed-key binding, directly or through merged
paths, may bind any name, regardless of whether the value is a scalar, function
or set. Lookup goes from inner frames outward. A known static binding in a frame
wins before that frame's unknown membership, regardless of declaration order.
Until the first uncertain frame, a supported static target is definite. After
that boundary, the nearest supported static target is retained only as a may
candidate; farther static bindings remain shadowed. With no supported candidate,
both target relations are empty. No outer target becomes definite again. A
computed name is never evaluated or invented as a declaration.

An unknown frame is an internal lookup boundary, not a public `Binding` or an
enumerated candidate for every possible name. `StaticScopes.qll` also places
boundaries where computed paths or set contributions may change recursion. Depth
ranks each semantic frame, rather than its composition root: twice the number of
enclosing frames, with possible inserted boundaries between ranks. A known
deeper recursive binding stays definite despite ancestor uncertainty; the
same-frame static-name guard also prevents moving an ancestor boundary onto that
binding. Direct computed keys are evaluated outside their own recursive set.
Values have no general exemption: in
`let c=99; a=rec { b=c; }; a.${"c"}=c; in a.b`, the computed sibling can capture
both uses of `c`; Nix encounters recursion. The layer keeps the outer `c` as
may, with no must target.

This is the approved frame abstraction with unknown names, not full Nix semantic
equivalence. Matching computed keys contributed first can change which recursive
frame exists. For example, Nix evaluates
`let b=99; a.${"inner"}={}; a=rec{inner=rec{b=3;probe=b;};}; in a.inner.probe`
to `99`: the earlier ordinary set suppresses the inner recursive frame. Using
`a.${"inner"}.x=7;` as the first contribution also yields `99`; using
`a.${"inner"}=rec{};` yields `3`. The resolver does not distinguish those key
values from other computed names when retaining a known deeper frame. Its
definite results have no general soundness guarantee across these matching,
reverse-order ordinary-set or nested-path contributions. The public API makes no
lossless mapping claim for the internal unknown-frame boundary.

`Bindings::Binding` enumerates actual lexical declarations, including unused
ones, and provider identities. A provider contributes semantic facts through a
reserved interface. Keys outside lexical frames, attribute selections and
variable uses are excluded. Lexical bindings have source locations; supplied
identities need not.

The public answers are available as module predicates and occurrence methods:

- `mayResolveTo` returns supported candidates.
- `mustResolveTo` returns a definite candidate only when no competing candidate
  exists; every must answer is also a may answer.
- `resolutionStatus` is `resolved`, `invalid` for conflicting binders, or
  `unavailable` when evidence cannot establish a definite answer.
- `resolutionReason` distinguishes `unique-binding`, `duplicate-binder` and
  `insufficient-evidence`.

Unavailable does not mean undefined or unused. `NameBindings.ql` reports
occurrence locations, status and definite target locations; zero target
coordinates mean no located definite target.

Inheritance copies named attributes; implicit scope supplies names from an
expression. [N2](implicit-scope.md) extends `LexicalScopeProvider` with
declarations and their frames, extra occurrences, and per-occurrence frame
exclusions. Occurrences are authenticated nodes with supported static-name
evidence: native variable uses or nodes selected by this provider. Selected
plain quoted names are allowed; computed names and unselected strings are
excluded. An exclusion starts lookup outside a frame, allowing an inherited name
to refer outward instead of to itself. These contributions use the same
nearest-frame selection, collision checks and identity rules as native
declarations. `ImplicitScopeProvider` supplies fallback candidates only after
explicit names, including the outer runtime frame. The production providers live
in `Inheritance.qll` and `ImplicitScopes.qll`. Source-backed implicit candidates
retain locations through the optional `getDeclaration` method; its default
returns no declaration.

The `OutermostBuiltinFrameProvider` hook admits generated runtime identities
through N2's production provider. Builtins are Nix's runtime-provided
primitives; their outer frame loses to local declarations. A runtime identity
identifies the selected Nix runtime; a model identity identifies the runtime
described by supplied facts. Only matching, nonempty identities admit a definite
builtin target. A missing or mismatched model leaves resolution unavailable; a
recognized builtin with incompatible evidence cannot fall through to an implicit
candidate. N1 provides this hook and synthetic checks; [M3](builtin-models.md)
generates the model. Production and synthetic providers use distinct identities
so their facts cannot combine.

`checks.x86_64-linux.codeql-nix-anchors` is the continuous-integration entry
point. It runs reviewed expected rows for scopes, merges, declaration
enumeration and synthetic providers, plus real Nix evaluation and safe-renaming
checks through the nonempty domain-test runner. An oracle is an independently
computed expected answer; the Nix checks provide this separate constraint.

To change resolution, update the appropriate layer and independent expectations
together. Preserve authenticated nodes, canonical merged identities,
explicit-name precedence, must within may, and invalid versus unavailable.
Extend the provider interfaces through their shared selection rules. Format
changed files with `treefmt` and run the owner check through continuous
integration. Imports, value evaluation and builtin-model generation remain
separate responsibilities; inheritance and `with` use the providers described
above.
