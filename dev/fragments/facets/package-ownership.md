## Package ownership and native composition

> **Last verified:** 2026-09-12 — all owners use native package, library,
> module, registry, and check composition.

An owner directory groups the implementation, checks, and declarative metadata
for a package. Public package namespaces come from the directory components
below `packages/<owner>/packages/`; the outer owner name has no namespace
meaning. Renaming that owner does not rename its public packages.

The shared engine indexes sources before evaluation, then uses native mechanisms
for each contribution: recursive nixpkgs package scopes, overlay composition,
raw backend module imports, and typed `evalModules` registries. Ownership checks
run before module priority can hide a competing definition. Shared namespace
containers are legal; package leaves and conflicting prefixes are exclusive.

`registry.nix` contributes update/cache metadata, documentation descriptions,
and owner-specific architecture fragment registrations. Use the injected
`repoPath ./relative/source.nix` to declare a mutable repository source path. It
derives the path from the actual owner location and removes Nix string context;
hardcoding `packages/<owner>/...` would defeat relocation. Root modules remain
responsible for workspace policy. Every owner is discovered; no central package
list or opt-in registry predicate controls discovery.

Registry claim discovery isolates each contributor's definitions while
evaluating conditions and imported arguments against the combined `config`,
`options`, and `_module.args`. The same context applies to root policy. A
registry key whose presence depends on another owner therefore remains visible
to collision checks, even when a competing definition uses `mkForce`.

`checks.nix` is a native module. It imports owner-local test modules and defines
`checks.<name>` derivations. Root check groups expose
`checks/<concern>/default.nix`; the workspace discovers those entry points one
directory deep. Supporting files and fixture trees are not recursively
registered. Adding a package check needs only owner edits; adding a root concern
needs no flake export-list edit.

Root and owner check names share an exclusive claim boundary. Each contributor
supplies isolated definitions for claim discovery, while its conditions and
imported module arguments see the combined `config`, `options`, and
`_module.args`. This keeps conditional checks visible without letting `mkForce`
hide another owner's claim. Native package option types reject non-derivation
check values. Root groups cover workspace policy and genuine cross-owner
contracts.

The shared harness in `lib/testing/module-harness.nix` discovers backend imports
from the same owner index as production. Package check modules may contribute
`testing.homeManagerAiPackages.<name>` to replace expensive binaries in wrapper
content tests, and `testing.moduleProbes` configurations to activate their pool
contributions. Probe each integration independently as well as together: native
option provenance follows priority filtering, so an all-enabled evaluation alone
can hide a second package's lower-priority claim. Keep each integration's probe
beside that owner. Runtime enables come from the shared runtime registry.

Keep backend-specific module paths raw so Home Manager and devenv evaluate them
independently with their own arguments. Consumer tests live under their package;
shared test infrastructure belongs in `lib/testing/`, while cross-owner
assertions stay in the appropriate root check concern.

Three evaluation boundaries are easy to break:

- **Discover overlay root names before forcing package values.** Computing
  overlay attribute names from a realized package world forces `final.stdenv`
  while nixpkgs is still discovering its fixed point, producing infinite
  recursion. Use indexed package paths and static ordinary-overlay claims for
  root names; realize values only beneath those names. Ordinary overlay claim
  paths must be independent of package evaluation.
- **Validate package values when accessed.** Index and collision checks may
  inspect all paths, but must not evaluate unrelated recipes. A package missing
  from a deliberately older test pin cannot prevent access to another package.
  Full flake validation still forces every exported derivation.
- **Platform filtering changes the discovery path type.** `builtins.path`
  returns a context-bearing string. Native discovery therefore passes string
  recipe paths for filtered trees. Remap both path and string recipes to the
  original owner tree, discarding context only from the relative suffix before
  appending it to the original path. Otherwise supported siblings lose relative
  imports outside the filtered tree or change derivation identity.

Namespace merging stops at derivations. A generic recursive attrset merge would
retain fields from a previous package while replacing its `drvPath`, creating a
hybrid package. Preserve namespace neighbors and replace package leaves whole.

Package recipes receive this flake's pinned `pkgs`, independently of the
consumer pin. Shared packaging helpers arrive through `packageLib`; package
implementation files should not encode a relative route back to the repository
root. Consumer policy, including the existing unfree guard, belongs at overlay
assembly rather than inside a package's source/build recipe. The composer guards
only owned package leaves with `lib/facets/unfree-guard.nix`, preserving
existing namespace neighbors and avoiding duplicate wrappers.

`lib/default.nix` contributes public helpers, using native module options with
raw leaf values. Functions retain their `functionArgs`; option declarations,
option types, and callable attrsets are atomic values whose internals must stay
lazy. Private helpers beside that entry point are not exported automatically.
Backend directories require `default.nix`; ordinary `.nix` sidecars in
`modules/` remain private to the backend modules that import them.

The flat flake package projection comes from indexed leaf basenames. It rejects
collisions, including workspace outputs, before constructing the final attrset.
A nested namespace is available through the overlay while every leaf remains a
derivation at the flat flake boundary. Both flake and devenv use the same
repository composer; document generation uses its package-independent registry.
