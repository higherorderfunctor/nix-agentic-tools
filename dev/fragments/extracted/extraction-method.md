# Extraction method: eval, then AST, then regex

> **Last verified:** 2026-10-15 — operator rule, restated after the Kiro rollout
> regex refused a new field in 2.30.0.

Every extractor picks the least brittle method its source allows. The method
follows the SOURCE, not the author's habit. This is the operator's standing
order and it has been restated many times. Do not make them restate it.

1. **Eval or copy.** Ask the program for its own answer: run it, call tsserver
   or the TypeScript compiler API, import the module and print the computed
   object. When the source is JSON (a file, or a JSON block embedded in a
   binary), parse it with a JSON parser and copy it. A transform is fine when it
   serves the reader: take a subtree, or normalize. Copy enough that the reader
   has everything it needs, not a 10% slice. This only breaks when the file or
   the anchor (a variable name, a key) goes away.
2. **AST.** When eval is not feasible: ast-grep, tree-sitter, Python `ast`. It
   survives code moving around as long as the shape matches. Walk the typed
   nodes for the VALUES too. Locating with AST and then running a regex over the
   matched text is the regex tier, not the AST tier.
3. **Regex.** Last resort, for prose or an already-decoded string that no parser
   can read. Each use carries a comment saying why tiers 1 and 2 cannot supply
   it, and a fixture a naive pattern gets wrong.

Locating a JSON block inside a binary with a short anchor pattern, then decoding
it with `json.JSONDecoder().raw_decode`, is tier 1. The pattern only finds the
start; the parser reads the value.

## What the extractor does NOT do

- **Support only the pinned version.** No legacy shapes, no fixtures for
  releases we no longer pin.
- **No field allow-lists in the extractor.** Copy what the source holds. When
  the shape changes, the hand-written reader that consumes the fact fails, and
  that failure is the design: fix the reader.
- **Fail when it cannot extract.** Never default, skip or count around a miss.

Extractors write through the facts contract in `lib/extracted/` (see
`facts-contract.md`); do not add a per-owner loader.

## Settled — do not relitigate

- **Kiro rollout manifest, 2026-10-15.** The extractor in
  `packages/kiro-cli/lib/packaging.nix` matched each manifest entry with a regex
  against a fixed field list. 2.30.0 added `internal_treatment_percent` to
  `v3_prompt`, the regex missed it, and every update sweep held kiro-cli back
  from 2026-10-13 to 2026-10-15. The manifest was valid JSON the whole time.
