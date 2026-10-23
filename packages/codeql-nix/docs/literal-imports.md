# Literal file imports

> **Last verified:** 2026-10-23 — I2a connects proven builtin import calls to
> admitted literal files through the authenticated source map.

An import site is a call whose function resolves definitely to Nix's builtin
`import`. An import edge links that site to an admitted source file.
`Imports.qll` supplies this static relation; `ImportGraph.ql` reports its sites
and targets. An edge proves a source dependency that syntax and admission
establish. It never says the call ran, the imported value was forced or
evaluation succeeded. Ordinary imports have isolated file scope: caller bindings
do not become declarations in the imported file. Module-collector observations
remain a separate graph.

## Resolve the function first

The library reuses [lexical resolution](lexical-scope.md),
[implicit scope](implicit-scope.md) and
[generated builtin identities](builtin-models.md). A bare `import` must resolve
definitely to the compatible builtin identity. For `builtins.import`, the
namespace variable must resolve definitely to builtin `builtins`, and the
selected member must share the global import identity. Parentheses around calls'
functions and arguments are accepted through the private syntax bridge.

A local function or argument named `import`, or a local `builtins` set, cannot
establish a site from spelling alone. Missing or incompatible model fingerprints
likewise cannot establish builtin import sites. This preserves name precedence
and model compatibility rather than adding a second name resolver.

## Resolve the file through admitted identities

Only a path expression composed entirely of literal path fragments supplies a
candidate. Relative paths start at the importing file's canonical directory
recorded in the [authenticated source map](source-identity.md); absolute paths
supply their own base. Component normalization removes `.` and folds `..`.
Resolution never uses the query process's working directory or searches the live
filesystem.

The map associates each full root/path/content-hash identity with canonical
archived and admitted lexical paths. A target exists only when the normalized
candidate matches either authenticated target spelling. This preserves contained
target symlinks while symlinked sources still use their canonical directory. An
admitted sibling root can therefore supply a target; restricting lookup to the
importing root would lose valid edges. An existing file outside the admitted set
supplies no target. A same-basename file in another directory cannot substitute
for a missing target.

Raw syntax can be shared by logical aliases. Keep the source file argument
correlated throughout `getTargetFile(source)`, `getStatus(source)` and
`getReason(source)`: two files with identical bytes in different directories can
have different relative targets. Full source and target identities remain
available through the file relation; the table query reports relative path
names, which alone do not distinguish roots or hashes.

## Public answers and limits

`Imports::StaticImportSite` represents proven builtin calls, including calls
with unresolved arguments. `getTargetFile(source)` returns admitted literal
targets. `getStatus(source)` is `resolved` when a target exists and
`unavailable` otherwise. `getReason(source)` is empty for resolved sites and
distinguishes:

- `dynamic-path`: the argument has no supported literal path, including
  interpolated paths, strings, variables and search paths.
- `missing-input`: a literal path has no matching admitted target, including
  missing files and files or roots outside the admitted set.

`Imports::importSite` and `ImportGraph.ql` report source path, callee line and
column, status, target path and reason. An unresolved target is an empty string.
Shadowed calls produce no site row.

Directory imports, implicit `default.nix` selection, search-path lookup and
`NIX_PATH` mappings have no resolution semantics in this slice. Neither dynamic
values nor filesystem existence alone justify a target. Generated syntax access
stays inside `RawBridge.qll`; the import layer reuses existing source relations
and adds no evaluation tables.

## Verification and changes

`checks.x86_64-linux.codeql-nix-anchors`, explicitly imported by the owner's
`checks.nix`, runs `checks/fixtures/imports/test_imports.py` through the
existing nonempty domain runner. The suite runs frozen
`ql/test/imports/ImportGraph.expected` rows through the installed extractor and
checks the production query separately. It also changes the installed model
fingerprint and requires no inferred sites.

Independent real Nix evaluations cover shadowing, relative paths from a
different process directory, missing files, applied imported functions and
isolated scope. The source-map test checks exact source/target root-path-hash
pairs for aliases, distinct physical bases, sibling and absolute targets, a
basename decoy, interpolation and files outside the admitted set. Its separate
Nix witness arrays expose the values that static admission deliberately leaves
unknown.

When changing resolution, update reviewed expected rows, exact identity
assertions and independent Nix witnesses together. Preserve definite builtin
identity, source correlation and the admission boundary. Extend literal
recognition through the private bridge. Directory or search-path support needs
its own verified evaluator rules and consuming tests. Format changed files with
`treefmt`, run the owner check through CI and update this note when these
obligations change.
