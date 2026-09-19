# Semantic library: session bootstrap

Read this when the operator steers a `feat/strictdoc-trial` session toward the
semantic library. The work lives on branch `feat/strictdoc-semantic-gate1`
(draft PR #1762, base `feat/strictdoc-trial`). Its observable behavior is the
specification for a distilled library; its code, layout and prose are not.
Invoke the `distill-prototype` skill before writing anything.

## Where things are

All paths are under
`fixtures/strictdoc-semantic-library/contract/gate2/dsl-review/` on that branch.
From a trial worktree, read them with
`git show origin/feat/strictdoc-semantic-gate1:<path>` or from the branch's own
worktree beside the primary checkout.

| Read                                                                 | What it is                                                                                                                                                    |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`                                                          | The accepted guide: one chapter per concept, code first, `examples.nix` as Appendix A.                                                                        |
| `examples.nix`                                                       | The accepted authoring surface for the neutral FOO/BAR/BAZ model.                                                                                             |
| `contract.md`, `bundle.json`                                         | The lowered contract: one flat record per rule, selector plus check, `all`/`any`/`not` over eight leaf kinds, `requires` edges, closed keyword and code sets. |
| `candidate.json`, `baseline.json`, `results.json`, `invocation.json` | Input and output shapes on the drawn base corpus.                                                                                                             |
| `dsl.nix`                                                            | The lowering stub. Imports `packages/strictdoc-grammar/lib/dsl.nix` by relative path; the library belongs beside that file.                                   |
| `backend/`                                                           | Standard-library Python evaluator, conformance harness, 88 expected envelopes under `fixtures/`, and `export-candidate.sh`.                                   |

Ignore everything else under `contract/gate2/`: `recommended.nix`,
`tutorial-dsl.md`, `authoring-prototype/`, `normalized-authoring/`, `research/`,
`runtime-pairing/`, `provenance/` and the round-3 README and contracts are the
rejected keyed-era packet and prior research. They must not shape the library.

## The operator's bars, all binding

- `packages/strictdoc-grammar/values.nix` is the readability idiom: bare
  constructors via `inherit`, ordered lists, one line per rule, reuse by named
  value; no helper factories, no `self:` binders, no fixed-point wrappers.
- Grammar is the Django model; semantics are its Meta: an element's
  `constraints` list beside `fields` and `relations`.
- A rule is a selector plus a check, with `all`, `any`, `not` over named leaves.
- `count` compared with `lt`, `lte`, `gt`, `gte`, `eq` is the lowest form of
  cardinality; `atMost`, `atLeast`, `exactly` are sugar over it.

## Traps measured on the branch

- The trial already has `dev/scripts/sdoc_semantics`, the state-field lifecycle
  engine. The prototype's package is also named `sdoc_semantics` and is a
  different thing. Naming and placement are the first decision; record it on a
  DEC node before code moves.
- `export-candidate.sh` wraps `strictdoc export --formats=json`. Run it from the
  project root, never a `documents/` directory, because the `@repo` grammar
  alias resolves through the root's `strictdoc_config.py`.
- The fixture suite runs inside the fixture's devenv shell:
  `cd fixtures/strictdoc-semantic-library && devenv shell -- contract/gate2/dsl-review/backend/run-fixtures.sh`.
- About 690 `contract.md:NNN` citations in backend text are stale. Cite section
  headings in anything new; never carry line numbers over.
- One fixture directory is spelled
  `closing-boundary-again-hides-existing-r-rejected` because the spell checker
  rejects the shorter word; keep it.

## Behavior that must survive a distillation

- Every construct the guide teaches lowers to the same `bundle.json` for
  `examples.nix`, `counting.nix` and the `note-state-field` model.
- `composition.nix`: `sameNormalized`, `deduplicated` true; `conflict` throws.
  `counting.nix`: `sugarEqualsLowest` true. The keyword and prerequisite throws
  in `transcript.txt` still fire.
- All 88 fixture envelopes pass on the contract's normative fields; the packet
  sample reproduces.
- Exporting `fixtures/strictdoc-semantic-library` equals `candidate.json`.

## Decisions that stay open

Fields referenced by name rather than declaration id; whether `at` may wrap
`all`/`any`/`not`; choice fields as their own semantic type; the
records-versus-owner field check asymmetry; hard-fail versus skip when
`nix-instantiate` is absent; blocked ranking above violated at the envelope; the
19 runtime-scope catalogue cases deferred to Scribe wiring. They are the
operator's; list them, do not resolve them.

## Working rules

Own worktree off the exact base commit, pushed at the first commit; no merge and
no PR from the working session. Do not change behavior: a difference from a
fixture is a bug in the port unless a contract sentence the fixture violates can
be cited, and then the fixture is fixed and the commit says so. Delegate bounded
work to clean-context subagents sized deliberately; keep the steering session's
exploratory context out of implementers. Report contradictions rather than
patching around them.
