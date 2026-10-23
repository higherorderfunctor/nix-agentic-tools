# Nix language integration gate

> **Last verified:** 2026-10-23 — R0 retires F0 after installed Step 0
> acceptance, promotes its pinned Rust syntax writer into production and
> preserves lookup, exact-text and coordinate proofs in owner checks.

## Purpose and fit

The integration gate now exercises the
[installed extractor](installed-extractor.md) and its separate library,
replacing the disposable syntax/TSV join. Installed
[Step 0 acceptance](step0-query.md) supplies real module metadata and
independent Nix oracles. F0's bootstrap relation, TSV producer, packs, duplicate
queries and check are removed; production checks own their surviving proof
obligations.

`lib/kit.nix` builds the shared Rust implementation from `src/`.
`src/Cargo.toml` and `src/Cargo.lock` preserve the existing vendoring identity;
the Cargo package name `nixql-bootstrap` remains solely to keep pinned
dependency resolution unchanged. The library crate is `nixql_syntax`, called by
`src/anchors.rs` and the raw writer. `src/generate.rs` uses the same inputs for
schema generation. Production assembly continues through `lib/packaging.nix` and
the existing CodeQL owner's engine customization.

## Compatibility pins

- CodeQL CLI: `2.27.3`, asserted by production packaging.
- Grammar: `nix-community/tree-sitter-nix` commit
  `38a15330421d20f3a4d380759f9634d39ba3d8ec`; crate `0.3.0`.
- Kit: `github/codeql` commit `a1575b98a8cc19bcfa7bb6cb41be688cb3dae65c` from
  `codeql-cli/v2.27.3`; crate `codeql-extractor` `0.2.0`.
- Parser runtime: `tree-sitter` `0.26.13` in the committed Cargo lock.

Fixed-output source hashes and the Cargo vendor hash remain in `lib/kit.nix`. An
engine, grammar or kit update requires re-auditing compatibility and all
selected string-emission paths; moving the source does not refresh that audit
automatically.

## Production lookup and coordinate proof

`checks/installed.nix` registers `checks/fixtures/installed/test_r0.py` through
the existing nonempty domain runner in
`checks.x86_64-linux.codeql-nix-installed`. The coordinate case creates a
database through the installed coordinator and queries the production generated
syntax and location adapter. Its six independent expected rows preserve
identical `41` tokens in distinct files, a recovered parse and exact
integer-token spans.

The coordinate fixture contains CRLF, a tab and UTF-8 `é` before `73`. One-based
inclusive byte columns place `73` at line 2, columns 27–28 and `97` at line 3,
columns 10–11. The recovered file retains `41` at line 3, columns 10–11. These
rows establish those spans and file identities; the separate
[anchor check](source-identity.md) retains empty-span, ambiguity and broader
source-association coverage.

The negative lookup case invokes the bare engine with an empty search path. It
requires extractor resolution to fail with a diagnostic naming `nix`, and query
compilation to fail naming the missing production library
`nix-agentic-tools/nix-all`. The customized command supplies these products
itself, so it cannot serve as the missing-product control. These checks prove
local missing-product refusal, without claiming a general network fallback
policy.

## Exact text before kit clipping

`src/syntax.rs` checks converted token text and normalized file/folder paths
before the pinned kit can clip tuple strings beyond 1,048,576 UTF-8 bytes. The
selected extraction path emits source text through token values; grammar product
tables carry labels and integers. Diagnostic messages also contain paths, so a
bound over the selected kit templates and grammar/schema names first establishes
whether direct extraction is safe.

When the bound cannot guarantee safety, the writer performs private extraction
at a short virtual path, decodes its diagnostic strings and restores the actual
diagnostic path before checking their byte lengths. Only then may real
extraction publish TRAP by rename. This applies to ordinary and recovered trees.
Alternate kit extraction paths and emission changes require a fresh audit.

`src/preflight.rs` exposes `nixql-preflight` over this same production function.
It reads source bytes and a synthetic logical path without creating or archiving
a file at that path. Oversized arguments return exit 2, bounded
`text-field-too-large` stderr and no completed TRAP.

`checks.x86_64-linux.codeql-nix-anchors` runs
`checks/fixtures/installed/test_preflight.py` against that production binary.
Its 28 cases cover six token/path categories at 1,048,575, 1,048,576 and
1,048,577 bytes, plus ten parse-error and ordinary-tree diagnostic cases.
Accepted strings must round-trip through decoded real TRAP tuples; oversized
fields must refuse publication. The retired TSV producer's three derived-path
cases disappear with that producer; production evaluation retains its own
transaction validation.

## Changing this gate

Keep integration proofs in the existing installed and anchor checks, with
expected rows independent of extractor output. Change shared Rust code under
`src/`, preserving the Cargo lock and vendoring pins unless intentionally
updating dependencies. Update consumers through `lib/kit.nix` and
`lib/packaging.nix`; keep one production writer and the existing packs.

After changing pins, selected kit emission paths, preflight or location
handling, re-audit exact text and run the affected installed, anchor,
raw-inventory and Step 0 owner checks through CI. Format changed files with
`treefmt` and regenerate scoped instruction projections after changing these
architecture notes. A passing raw coordinate query alone does not replace
installed module-query or authenticated source evidence.
