# Raw syntax generation

> **Last verified:** 2026-10-23 — S1 checks standalone location rows against
> exact archived fixture bytes and rejects missing/corrupt archive entries; S2
> adds the authenticated source driver and companion raw bridge.

## Purpose and fit

`lib/packaging.nix` owns the raw generation products: `generator`, `generated`
and `library`. The generator invokes the pinned tree-sitter kit rather than
maintaining a second AST schema. `generated/` commits the combined schema,
generated QL and manifest for diff review. These are private syntax interfaces;
later meaning modules must absorb generated class churn instead of exposing it
as a stable public API.

`lib/kit.nix` shares F0's grammar/kit pins, Cargo lock and vendoring with S1. It
builds the small `src/generate.rs` entry point alongside the private bootstrap
fixture. That reuse supplies generation and the test-only syntax producer; it
supplies the raw binary reused by S2's source driver, without installing the
final extractor distribution or an evaluation producer. `lib/packaging.nix`
requires the existing CodeQL owner's engine version to remain `2.27.3`, so an
engine update requires a kit compatibility audit.

## Generated artifacts and manifest

`src/generate.rs` passes the pinned grammar's node types to the kit without F0's
disposable target relation. `src/generate.py` appends one newline and the exact
F1 `schema/evaluation.dbscheme` bytes to the generated schema. Its outputs are:

- `nix.dbscheme`: kit syntax and handwritten evaluation relations in one schema.
- `nix/internal/generated/Ast.qll`: the kit's generated syntax classes.
- `schema-manifest.json`: sorted unique class and table names, grammar/kit
  revisions and the SHA-256 digest of the combined schema bytes.

The inventory reads declaration forms after removing comments; it is not a
general QL parser. Empty class/table inventories fail. The manifest records
generated class names and combined-schema table names, including the F1
relations, so both AST churn and handwritten-schema drift remain visible.

The source library's `ql/lib/nix.dbscheme` symlink selects the committed
combined schema. The assembled `library` instead copies the fresh generation
outputs, pack manifest and location adapter into one pack and adds same-basename
schema statistics. Neither product includes the proprietary engine. This slice
does not assemble the final language distribution.

## File and location interface

`ql/lib/codeql/Locations.qll` supplies the `overlay[local]` interface imported
by generated syntax. `File` reads absolute paths from `files` and derives
source-root-relative paths using `sourceLocationPrefix`. `Location` reads its
file and start/end line/column from `locations_default`. This adapter depends on
the combined schema directly and declares no other language-library dependency.

The adapter preserves F0's file/location interface; it does not authenticate
source snapshots or associate handwritten anchors with raw nodes. S2's
[source driver and RawBridge](source-identity.md) supply those joins through a
namespaced companion metadata index. A path/location row alone does not
establish a unique syntax anchor or expression-to-value provenance.

## Check and change procedure

`checks.nix` explicitly imports `checks/raw-inventory.nix`, exposing
`checks.x86_64-linux.codeql-nix-raw-inventory` through the existing owner check
path. The check:

1. Runs generation twice and compares both trees, the derivation output and the
   committed `generated/` tree byte for byte.
2. Runs the independent inventory tests against the manifest, schema and F1
   relation inventory, comparing class/table lists and the schema digest with
   the actual generated artifacts.
3. Uses the bare engine, this library and a private test extractor to run
   `ql/test/raw-inventory/Locations.ql`. The reviewed rows require generated
   tokens to resolve through locations to distinct files, including a recovered
   parse and matching token text in two files. It retains the test database and
   checks that its source archive contains the exact bytes for each fixture
   named by those rows. Removing an expected entry or corrupting its bytes in
   that extracted archive must fail the same acceptance command.
4. Removes the local adapter from a copy of the library and requires compilation
   to fail mentioning `codeql.Locations`. This prevents another language pack
   from silently satisfying the required import.

The fixture check verifies its listed one-based inclusive coordinates and file
paths and archived fixture bytes; it does not replace S2's Unicode, CRLF,
empty-span, ambiguity or exact-text refusal coverage. The private extractor is a
check input, not an installed user interface.

To change generation, update the relevant pin or entry point, run
`nixql-generate OUTPUT_DIRECTORY` from the `generator` product and copy its
complete outputs into `generated/`. Review the schema, generated class and
manifest diffs together; never patch generated raw QL or schema by hand. Change
F1 first for handwritten ABI changes. Format changed files with `treefmt` and
run the owner raw-inventory check through CI. Re-audit kit compatibility when
the engine or kit changes, and revisit this note when generation or
location-interface obligations change.
