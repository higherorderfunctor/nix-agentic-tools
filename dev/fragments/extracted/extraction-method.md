# Extraction method: eval, then AST, then regex

> **Last verified:** 2026-10-15 — operator rule, restated after the Kiro rollout
> regex refused a new field in 2.30.0.

Every extractor picks the least brittle method its source allows. The method
follows the SOURCE, not the author's habit.

1. **Eval or copy.** Ask the program for its own answer: run it, call tsserver
   or the TypeScript compiler API, import the module and print the computed
   object. When the source is JSON (a file, or a JSON block embedded in a
   binary), parse it with a JSON parser and copy it. A transform is fine when it
   serves the reader: take a subtree, or normalize. Copy the whole value; take a
   subtree or normalize only for a named reader, never a 10% slice. This only
   breaks when the file or the anchor (a variable name, a key) goes away.
2. **AST.** When eval is not feasible: ast-grep, tree-sitter, Python `ast`. It
   survives code moving around as long as the shape matches. A pattern may
   wildcard what we don't care about (a string literal's wording, an argument we
   ignore); that is still the AST tier. Walk the typed nodes for the VALUES we
   do care about. Locating with AST and then running a regex over the matched
   code text to pull values out is the regex tier, not the AST tier. A regex
   over an already-decoded string value is fine.
3. **Regex.** Last resort, for prose or an already-decoded string that no parser
   can read. Each use carries a comment saying why tiers 1 and 2 cannot supply
   it, and a fixture a naive pattern gets wrong. A fact that measures a byte
   patcher's own matcher (Kiro's `rolloutPatchability`) is exempt: the matcher
   is the thing measured.

Locating a JSON block inside a binary with a short anchor pattern, then decoding
it with `json.JSONDecoder().raw_decode`, is tier 1. The anchor bounds the block,
the parser reads the value, and a missing bound fails with its own message.

## Rules

- **Support only the pinned version.** No legacy shapes, no fixtures for
  releases we no longer pin.
- **No field allow-lists in the extractor.** Copy what the source holds. When
  the shape changes, the hand-written reader that consumes the fact fails, and
  that failure is the design: fix the reader.
- **Fail when it cannot extract.** Never default, skip or count around a miss.
- **No layer between the extraction and its readers.** Readers are hand-written
  and read the copied value directly. Do not build a normalized meta format or
  automation that carries upstream changes up to them; when a reader breaks, an
  LLM or a person fixes the reader, and that is cheaper than the machinery.

Extractors write through the facts contract in `lib/extracted/` (see
`facts-contract.md`); do not add a per-owner loader.

## Settled — do not relitigate

- **Kiro rollout manifest, 2026-10-15.** The extractor in
  `packages/kiro-cli/lib/packaging.nix` matched each manifest entry with a regex
  against a fixed field list. 2.30.0 added `internal_treatment_percent` to
  `v3_prompt`, the regex missed it, and every update sweep held kiro-cli back
  from 2026-10-13 to 2026-10-15. The manifest was valid JSON the whole time.
