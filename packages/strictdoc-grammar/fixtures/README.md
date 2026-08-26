# fixtures

`foreign.nix` is the DSL value set and `foreign.sgra` is what it renders to,
byte for byte. Together they are the positive fixture: a deliberately foreign
grammar exercising the half of StrictDoc's surface this repository's own five
node types never touch — a composite element, a `VIEW_STYLE`, a field
`HUMAN_TITLE`, a `Child` relation, a `File` relation carrying a `ROLE`, a
role-less `Parent` relation, a `Tag` field, a `MultipleChoice` field, an element
declared with no `PREFIX`, and a quoted choice option containing parentheses. It
parses and exports clean under strictdoc 0.28.3, so anything the surface emits
for it must too; it backs acceptance item 7, and nothing in it is specific to
this repository.

One thing `foreign.sgra` deliberately no longer carries. It was first written
with `GPL-3.0-or-later` quoted as well, which is legal input — but strictdoc
quotes an option **only** when it contains a parenthesis
(`GrammarElementFieldSingleChoice.get_unprocessed_options`), so that spelling is
one strictdoc's own writer never produces and the emitter therefore cannot
reproduce. `extract/compare.py` was run across the two spellings and reported
the models EQUAL — the redundant quotes vanish at parse, and `options` is
`['MIT (Expat)', 'GPL-3.0-or-later', 'proprietary']` either way — so the file
was normalized to the canonical form and the byte gate kept. That is the
difference between the two gates, in one measurement: semantically identical,
not byte-identical, and only one of the two spellings is canonical.

`negative/` holds one file per case that must fail, named for what it proves,
split by the layer that owns the rejection. The two `.nix` files are **ours, at
Nix evaluation**: duplicate field titles and duplicate relation roles have no
rule anywhere in strictdoc, parse clean and export exit 0, and the silent
recovery runs in opposite directions (last declaration wins for fields, first
wins for relations) — they are the only two checks that belong in this package.
They are written as plain data against the normalized element shape rather than
through the DSL, so they do not track constructor names. The six
`*.sgra.invalid` files are **strictdoc's, at export**:
`reverse-role-without-role`, `section-not-composite` and `text-composite` are
semantic checks reported by `SDocValidator` during the traceability-index build,
while `option-with-comma`, `lowercase-tag` and `reserved-tag-prefix` (a
`DOCUMENT`-prefixed tag) are rejected earlier still, by the textx parse of the
`.sgra` itself.

| Fixture                                           | Rejected by                           |
| ------------------------------------------------- | ------------------------------------- |
| `negative/duplicate-field-title.nix`              | this package, at Nix evaluation       |
| `negative/duplicate-relation-role.nix`            | this package, at Nix evaluation       |
| `negative/lowercase-tag.sgra.invalid`             | strictdoc, textx parse of the `.sgra` |
| `negative/option-with-comma.sgra.invalid`         | strictdoc, textx parse of the `.sgra` |
| `negative/reserved-tag-prefix.sgra.invalid`       | strictdoc, textx parse of the `.sgra` |
| `negative/reverse-role-without-role.sgra.invalid` | strictdoc, `SDocValidator` at export  |
| `negative/section-not-composite.sgra.invalid`     | strictdoc, `SDocValidator` at export  |
| `negative/text-composite.sgra.invalid`            | strictdoc, `SDocValidator` at export  |

Two things about those six are not cosmetic. The `.sgra.invalid` extension is
load-bearing: a whole-project `strictdoc export .` reads **every** `.sgra` under
the project root, referenced by a document or not, so a deliberately invalid one
committed as `*.sgra` breaks the repository's own export — measured, and the
reason the suffix exists. And a `.sgra` admits no comment syntax at all (a
leading `#` fails at 1:1 against `Expected '[GRAMMAR]'`), so these six carry
their expectation in the table above and in their filenames rather than in a
header line, which would otherwise make each one fail for the wrong reason.

Exercising a negative therefore means copying it into a throwaway project
outside the repository as `g.sgra`, beside a minimal `.sdoc` that imports it by
that bare filename, and asserting a non-zero exit — a copy each one needs
anyway, since `IMPORT_FROM_FILE` resolves only a bare filename next to the
document.
