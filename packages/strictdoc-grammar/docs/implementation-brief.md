# strictdoc-grammar — implementation brief

> **Last verified:** 2026-08-26. Written by the planning session that designed
> this milestone, for the sessions implementing it. Everything marked MEASURED
> was run against strictdoc 0.28.3 during that design. Do not re-derive it.

## What this is

A typed Nix option surface for StrictDoc's `.sgra` grammar files, **generated
from StrictDoc's own grammar definition** rather than hand-written, plus a
generator that emits a `.sgra` file from values written against that surface.

General purpose and intended for publication. It is **not** specific to this
repository's five node types — those are one consumer of it.

Delivers `SLICE-GRAMMAR-FROM-NIX`. Read that node before starting.

## Three layers, and why

```
strictdoc grammar  --extract-->  FAITHFUL .nix   (generated)
FAITHFUL           --normalize-> NORMALIZED .nix (generated)
NORMALIZED         <--maps to--  CONSUMER DSL    (hand-written)
```

Types flow **up** from strictdoc at generation time. Values flow **down** from
the DSL at authoring time, ending in a `.sgra` file.

- **Faithful** expresses exactly what a `.sgra` can express. No opinions. A
  value constrained by a regex is a string with that regex.
- **Normalized** is faithful with specific nodes replaced — deep-merge in
  spirit. A regex that is a pure literal alternation becomes an enum; a
  two-value alternation becomes a bool.
- **Consumer DSL** is hand-written sugar over normalized. It cannot weaken the
  types; it only saves typing.

All three are committed files. Layering is real, not a reasoning aid: an error
is traceable to the layer it came from.

### Every converter is a PAIR

A converter has a **type rewrite** (faithful type → normalized type) and an
**encoder** (normalized value → faithful value, on the way to the file).

`IS_COMPOSITE` is `strMatching "(True|False)"` faithfully and `types.bool`
normalized, so its encoder is `b: if b then "True" else "False"`.

**Encode only.** Reading `.sgra` back into Nix is out of scope. There is no
decoder.

## Settled decisions — do not relitigate

- **Generated, not hand-authored.** No enum, knob or field list is typed by a
  person. Upstream ships ~3 releases a month and a hand-written surface would
  not notice an addition.
- **Lists, not attribute sets**, for elements, fields and relations. StrictDoc's
  grammar has all three as ordered lists and order is enforced. Nix sorts
  attribute-set keys, which would silently reorder the emitted file.
  Consequence: duplicate detection is an explicit assertion, not a structural
  side effect.
- **`lib.types.attrTag` for the unions.** Field kind and relation type are
  genuine discriminated unions, not a common record with optional extras. This
  matters beyond taste: the module system's `addCheck` predicate silently never
  fires inside submodules, so post-validation guards do not run. A structural
  union has no such hole.
- **No semantic layer.** No contract flags, no relation target sets, no ordering
  policy, no lifecycle. Those belong to a consumer.
- **Completeness is the point.** Carry every native grammar feature — composite
  nodes, view styles, human titles, child relations, file roles, no-prefix —
  including the ones this repository never uses.
- **An unrecognized shape is an error, not a fallback to free text.** Declaring
  a value unconstrained is itself a named converter, so "we decided this is free
  text" stays distinguishable from "nobody classified this".

## MEASURED — reach the grammar like this

StrictDoc assembles its own grammar into a plain string. **Byte-identical
between 0.28.2 and 0.28.3**, sha256 `4adcdb05…`.

```python
from textx import metamodel_from_str
from strictdoc.backend.sdoc.grammar.grammar_builder import SDocGrammarBuilder as B

mm = metamodel_from_str(B.create_grammar_grammar())   # the .sgra grammar
```

Two access paths, both needed:

- **Metamodel** — `mm[rule]._tx_attrs` (name, type, multiplicity), `_tx_inh_by`
  (an abstract rule's alternatives), `_tx_type`. Walking from
  `DocumentGrammarWrapper` reaches 25 of 43 rules; the rest are document-side.
  Yields the skeleton: element keys, the four field-type alternatives, the three
  relation-type alternatives, and that the file relation has **no**
  `reverse_relation_role` attribute at all.
- **Parser tree** — `mm[rule]._tx_peg_rule`, walked as arpeggio nodes
  (`Optional`, `RegExMatch.to_match`, `StrMatch.to_match`, `OrderedChoice`).
  **Required**, because the metamodel reports every attribute as `mult=1`
  regardless of optionality and flattens value vocabularies to `STRING`.
  Optionality and literal sets live here.

Literal sets arrive in **two shapes** and an extractor must handle both:

- named rules — `BooleanChoice` is an `OrderedChoice` of `StrMatch` children
- inline regex alternations — `IS_COMPOSITE` is `/(True|False)/`, `VIEW_STYLE`
  is `/(Plain|Simple|Inline|Narrative|Table|Zebra)/`

Convert a pattern to an enum **only** when it is a single group of pure literal
alternation. A character class, quantifier or nested group stays a regex check.
Never guess an enum from a pattern you did not fully understand.

### Running strictdoc in process

```bash
S=$(dirname "$(dirname "$(readlink -f "$(command -v strictdoc)")")")
PYTHONPATH=$(sed -n '3p' "$S/bin/.strictdoc-wrapped" | grep -o "\['[^]]*'\]" \
  | tr -d "[]'" | tr ',' ':')
```

The wrapper's third line carries every dependency's site directory, including
textx and arpeggio, which are not on the plain interpreter's path.

`nixpkgs#ast-grep` and `nixpkgs#python3Packages.ast-grep-py` are both 0.45.1.
ast-grep is tree-sitter based, bundles a Nix grammar, and its Python bindings
match and capture over Nix source in process — MEASURED.

**Use ast-grep as a MATCHER, not a rewriter.** A `fix:` rule emits one text
replacement and cannot produce a type declaration _and_ an encoder from one
match. Match, take the captures, emit both from Python. The owning attribute
name is reachable by walking up to the enclosing `binding` node, so the field
name is available alongside the pattern — MEASURED.

## MEASURED — the grammar's shape

Element keys: `TAG`, then an optional `PROPERTIES` block holding any of
`IS_COMPOSITE` / `PREFIX` / `VIEW_STYLE`, then a mandatory `FIELDS` (one or
more), then an optional `RELATIONS` (one or more if present). Nothing else
exists. Order is enforced.

Field keys, in this fixed order: `TITLE`, optional `HUMAN_TITLE`, `TYPE`,
`REQUIRED`. `REQUIRED` is mandatory on every field. Four `TYPE` spellings only:
`String`, `SingleChoice(...)`, `MultipleChoice(...)`, `Tag`.

Relations: `TYPE` is `Parent`, `Child` or `File`. Parent and Child take optional
`ROLE` and `REVERSE_ROLE`. **File takes `ROLE` but has no `REVERSE_ROLE`
production at all.**

Choice options: separator is exactly `", "`. At least one option, expressed as
rule structure rather than a regex. An option **may not contain a comma in
either quoted or unquoted form** — quoting only buys literal parentheses.

`Tag` is a constrained free-form label list, not a reference: charset
`[a-zA-Z0-9/|_ -]`, strict `", "` separator, no vocabulary, no referential
check. It normalizes to a list exactly like `MultipleChoice` does; the two
differ only by having a declared vocabulary. Shared encoder — join with `", "`.

Tag names: `[A-Z]+(_[A-Z]+)*`, no digits, no lowercase. Reserved via a
**prefix** lookahead on `DOCUMENT` and `GRAMMAR`, so `DOCUMENT_FROM_FILE` is
rejected too. `SECTION` parses but fails a semantic check unless composite;
`TEXT` and `REQUIREMENT` are legal.

## MEASURED — what the grammar does NOT cover

Live somewhere other than the grammar. Do **not** reimplement these in Nix;
leave them to strictdoc and use each as a negative fixture proving the gate
fires.

- reverse role without role → `backend/sdoc/error_handling.py:409`
- SECTION not composite → `:459`; TEXT composite → `:436`
- MID field missing when enabled → `:390`
- **None of these run on a bare parse.** The only callers of `SDocValidator` are
  `core/traceability_index_builder.py:390,468,520` and
  `core/traceability_index.py:357`. A clean-directory whole-corpus export is the
  only validation that ever happens to a generated grammar.

Two things strictdoc has **no rule for anywhere**, so they are ours to check:

- duplicate field titles — parses clean, the by-name lookup keeps the **last**
- duplicate relation roles — parses clean, the lookup keeps the **first**

Opposite directions, both silent, export exit 0. MEASURED. These are the only
two checks that belong at Nix evaluation.

Reserved field names are importable rather than hand-listed:
`RequirementFieldName.RESERVED_SINGLELINE_FIELDS` and `RESERVED_NON_META_FIELDS`
in `backend/sdoc/models/model.py`. They carry document-writing behavior
(single-line versus block values) that belongs to the CLI milestone, not here.

## The shape, as designed

```nix
kindType = types.attrTag {
  string         = mkOption { type = submodule plainBody; };
  tag            = mkOption { type = submodule plainBody; };
  singleChoice   = mkOption { type = submodule choiceBody; };
  multipleChoice = mkOption { type = submodule choiceBody; };
};

fieldType = submodule { options = { title = ...; kind = kindType; }; };

relationType = types.attrTag {
  parent = ...;   # role, reverseRole
  child  = ...;   # role, reverseRole
  file   = ...;   # role only
};

elementType = submodule {
  options = { tag; prefix; fields = nonEmptyListOf fieldType; relations = listOf relationType; };
};
```

Consumer DSL, hand-written, mapping onto that:

```nix
field = rec {
  mk   = k: title: body: { inherit title; kind.${k} = body; };
  str  = title:     mk "string"         title {};
  tag  = title:     mk "tag"            title {};
  one  = title: cs: mk "singleChoice"   title { choices = cs; };
  many = title: cs: mk "multipleChoice" title { choices = cs; };
  required = f: f // { kind = lib.mapAttrs (_: v: v // { required = true; }) f.kind; };
  raw = x: x;
};
rel = {
  parent = role: reverseRole: { parent = { inherit role reverseRole; }; };
  child  = role: reverseRole: { child  = { inherit role reverseRole; }; };
  file   = { file = {}; };
  raw    = x: x;
};
el = tag: props: body: { inherit tag; } // props // body;
```

Used as:

```nix
(el "EXAMPLE" { prefix = "EX-"; } {
  fields = [ (required (str "UID")) (many "LABELS" ["a" "b"]) ];
  relations = [ (rel.parent "Refines" "Refined_By") rel.file ];
})
```

There is no `optional` constructor — absence of `required` is optional.

`raw` is identity. It escapes the constructors, never the surface: MEASURED that
`raw` with choices on a string kind, two kinds at once, or an unknown kind are
all rejected.

## Acceptance

1. The extractor runs and produces the faithful surface with no hand-typed enum.
2. The normalizer produces the normalized surface plus encoders, and **fails
   loudly** on a shape it does not recognize.
3. The DSL evaluates and cannot weaken the types.
4. A `.sgra` emitted from DSL values **parses**, and the model strictdoc builds
   from it equals the model built from this repository's committed
   `docs/sdoc/grammar.sgra`. Semantic equality is the correctness gate.
5. Byte-identity against the committed file is the **regression** gate, allowed
   one deliberate normalization commit first if the emitter's canonical form
   differs from what was hand-written.
6. Negative fixtures fail: the two duplicate cases at Nix evaluation, the
   strictdoc-owned rules at export.
7. A deliberately **foreign** grammar — composite nodes, view styles, human
   titles, child relations, `Tag`, `MultipleChoice`, a no-prefix element —
   round-trips. This repository's five node types exercise about half the
   surface, and this is a general-purpose component.

Local invocation is enough. CI wiring is not required for this milestone.

## Hard rules for implementing sessions

- **Never run `fp-accept`.** Signing is the operator's key and an agent commits
  under their name.
- **Never set `AUTHORED_BY: human`.**
- Commit as you go, and update the node you are working on in the same commit.
- Log incidental findings to `docs/plans/strictdoc-tooling/` as nodes at
  `DEPTH: sketch` — one node per file, named for its UID lowercased. Do not
  narrate them.
- `strictdoc format` and `export` write a cache into `./output/` unless given
  `--output-dir`; `format` has no such flag, so run it with the worktree as cwd
  where `output/` is gitignored.
- Prototype quality. Nix evaluation and the checks are the review.
