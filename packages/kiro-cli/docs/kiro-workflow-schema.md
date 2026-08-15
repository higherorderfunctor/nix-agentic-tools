# Kiro workflow typed schema

> **Last verified:** 2026-08-14 (commit pending — body re-checked against the
> post-review heads of the two implementation branches, which this doc branch
> does not yet contain, and two claims corrected. The `input` bullet asserted
> that both reference documents teaching the removed field were already
> corrected; only `dev/references/kiro-workflow-ref.md` is, so the bullet is
> restated as a durable "surviving `prompt` / `input` text is stale" rule that
> holds both before and after the second correction lands. And "they share
> `engine-limits.json`, so they cannot drift" is narrowed to what that file
> actually pins — the caps, enums and watch intervals — because the two ports DO
> differ by one diagnostic code: `E-STOP-WHEN-SYNTAX` is TypeScript-only, for
> malformed assembled wire strings the authored Nix sum type cannot represent.
> Neither port claims whole code-set equality; the Effect side says so
> explicitly. Re-checked and still true: the caps, the single placement rule,
> the `repeat`-with-neither-stop-form rule, and the bare-`{{name}}` trap — the
> new `W-STOP-WHEN-LITERAL-TEMPLATE` warning covers empty or whitespace-only
> `stopWhen` templates, not undeclared names, so it does not touch that bullet).
> Prior: 2026-08-14 (commit 37b2bc39 — the `addCheck` trap was REFUTED as
> stated. It said `check` is a flat no-op because the module system calls it on
> each raw definition, where a submodule predicate sees `{}` and passes. The
> real mechanism is position-dependent: when the submodule is the option's own
> type, `fixupOptionType` rebuilds it and DISCARDS the check, so it never runs
> at all; inside an `attrTag` member it does run, but against the raw
> pre-default attrset. The conclusion survived — `apply` is still the only
> post-merge hook — but the count did not: four invariant sites, not three).
> Prior: 2026-08-14 (commit pending — first version, written against **kiro-cli
> 2.18.0 / KAS 2.18.0** by reading the shipped engine bundle directly).
>
> If you change `packages/kiro-cli/lib/workflow/**`,
> `packages/kiro-cli/schema/**`, or `checks/kiro-workflow-schema.nix` and this
> fragment is not updated in the same commit, stop and fix it.

Two implementations of one contract: `packages/kiro-cli/lib/workflow/` (Nix
option types) and `packages/kiro-cli/schema/` (Effect `Schema`). They share
`engine-limits.json`, so the constants it pins — caps, enums, watch intervals —
cannot drift between them. Nothing else is mechanically tied: the diagnostic
codes are kept parallel by review, not by a cross-language runner, and they are
not identical. `E-STOP-WHEN-SYNTAX` is TypeScript-only, because it reports on
malformed assembled wire strings the authored Nix sum type cannot represent in
the first place.

**The format is in no public documentation.** 194 Kiro doc pages contain zero
occurrences of every schema identifier; workflows are absent from the CLI 3.0
feature table, the experimental register and the ACP extension list. The shipped
KAS bundle is the only spec. Do not "check the docs" — there are none, and a
plausible-sounding doc claim about this format is fabricated.

## The three-layer split, in both languages

| Layer     | Nix                        | TypeScript      | Proves                            |
| --------- | -------------------------- | --------------- | --------------------------------- |
| shape     | `types.nix`                | `schema.ts`     | what ONE node proves about itself |
| tree      | `analyze.nix`              | `analyze.ts`    | counts, ids, orientation, refs    |
| compile   | —                          | `type-level.ts` | the tree rules, at compile time   |
| transport | `render.nix` / `parse.nix` | —               | authored shape <-> wire JSON      |

An option type sees one node at a time and never its siblings or ancestors, so
everything tree-shaped has to live in the analyzer. That is not a limitation
worked around; it is the same split the engine itself makes between its Zod
schema and `src/workflow/validate.ts`.

## Authored shape is not wire shape (Nix only)

`render.nix` bridges them. Each divergence buys a constraint the wire cannot
express:

| wire                            | authored                         |
| ------------------------------- | -------------------------------- |
| `{type = "step"; …}`            | `{step = {…};}` (`attrTag`)      |
| `stopWhen = "wait.terminal"`    | `stop.when.watchTerminal`        |
| `stopWhen = "{{a}} contains X"` | `stop.when.contains`             |
| `jsonPath = "state.drained"`    | `jsonPath = ["state" "drained"]` |
| `handler` + `config`            | `watcher.<handler>`              |

`attrTag` diverges from the house convention (one wide submodule, nullable
fields, an assertion). That is deliberate: the house style makes every
per-variant field optional and defers shape to an assertion, which is the
failure mode this file exists to prevent. `attrTag` gets exactly-one-variant and
per-variant required fields at TYPE level.

`parse.nix` is the inverse, so existing `.kiro/workflows/*.workflow.json` can be
checked and so parse -> render round-trips are testable. The vendor corpus
round-trips byte-identically; that property is what proves the divergence is
faithful.

## The `basis` taxonomy

Adopted verbatim from `fixtures/kiro-primitives/workflows/contract.jq` rather
than reinvented. `engine` = the engine refuses it. `policy` = the engine ACCEPTS
it, and the rule exists because acceptance is silent and the consequence
expensive. Keeping them separable is load-bearing: a policy rule would reject
working definitions, including vendor-shipped ones. Match on `code`, never on
`message`.

## Traps that cost real time here

- **`lib.types.addCheck` is position-dependent for submodules.** When a
  submodule is an option's own type (including through `nullOr` or `listOf`),
  `fixupOptionType` rebuilds it and discards the check. Inside an `attrTag`
  member the check instead runs against the raw, pre-default attrset. Neither
  position sees the merged value, so neither is reliable for a cross-field
  invariant. Overriding `merge` does not help: the module system evaluates the
  nested option tree without calling the outer `type.merge`. **`apply` is the
  only post-merge hook and behaves consistently at all four invariant sites.**
- **Nix regexes are POSIX ERE.** `\{` is not a defined escape and makes the
  whole pattern invalid at runtime; a backslash inside a bracket expression is a
  LITERAL backslash, so `[^.$*\[\]]+` does not mean what it looks like and
  rejected every ordinary property name. Bracket the braces (`[{][{]`) and
  prefer explicit predicates over clever classes.
- **Never symlink a generated `.workflow.json` from the store.** Discovery stats
  the file (following symlinks) but the launch path resolves it through realpath
  and requires the result inside a workspace root — `/nix/store/...` never is.
  So the recipe lists fine and then refuses to launch. `home.file.<…>.text`
  symlinks into the store and is therefore the wrong delivery mechanism; copy at
  activation instead. Code-read, not measured — probe P-01.
- **`{{previous.output}}` and cross-branch references are load-time ERRORS**,
  not runtime surprises. But a bare `{{name}}` that is not a declared input is
  never an error at all — it stays literal in the prompt forever.

## Rules worth knowing before authoring a definition

- Caps: **20 step nodes** (containers are free), **nesting depth 8**,
  **maxIterations 1000 inclusive**. All three are `DEFAULT_*` constants in
  `validate.ts` with no caller override anywhere in the bundle.
- **The only node-orientation rule** is that a step declaring `completion` may
  not appear beneath a `parallel` — checked against ANY ancestor. Nested repeats
  and nested parallels are both legal.
- A `repeat` may define **neither** stop form. Both vendor authoring documents
  claim exactly one is required; they are wrong, and the vendor's own
  `autoresearch` recipe ships with neither.
- The step-level `input` field is **removed** and now rejected loudly. Two of
  this repo's reference documents taught it —
  `dev/references/kiro-workflow-ref.md` and `dev/references/kiro-workflows.md`.
  If either still offers `prompt` / `input` as alternatives, that text is stale,
  not a second opinion; row `P-02` of the ref's §8 register is the run that
  settles it against a live engine.
- `modelId` and `effortLevel` are deliberately bare strings. The model catalog
  is fetched from the control plane at runtime (compiled-in default: empty), and
  the legal effort set is per-model and server-supplied. A literal union would
  reject values the server accepts.

## Running the checks

`nix flake check` covers the Nix half, including the vendor corpus. The
TypeScript half is manual by design — see `packages/kiro-cli/schema/README.md`.
Open measurement debt is registered in `dev/references/kiro-workflow-ref.md` §8
as rows `P-01`..`P-12`.
