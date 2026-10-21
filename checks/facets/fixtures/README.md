# Tracked production-boundary facet mock

This fixture keeps discovery separate from registry realization and publishes no
mock package, overlay, module, or library. The shortest useful read is:

1. [`lib/facets.nix`](../../../lib/facets.nix) for the system-independent index
   and registry-specific realizers;
2. [`production/git-revise/`](./production/git-revise) for a vertically owned,
   production-shaped package boundary; and
3. [`checks/facets/facet-mock.nix`](../facet-mock.nix) for generic orchestration
   and cross-owner assertions.

`production/` is add-only by owner. The git-revise owner contains an owner
`default.nix`, package recipe, overlay, directory-shaped Home Manager and devenv
modules, native check modules, a declarative registry contribution,
documentation, fragments, and Nix/JSON sidecars. Discovery records contribution
and metadata provenance without importing the metadata-only files. The fixture
consumer evaluates raw module paths with the native module system.

Packages use `makeScope`, `callPackage`, and `packagesFromDirectoryRecursive`;
overlays use lexical `composeManyExtensions`, each contribution deep-merged into
`prev` with `recursiveUpdateUntil` up to derivations; declarative values use
`evalModules` with explicit types. The only custom merge is exclusive-owner
validation before those native mechanisms run. The mixed-priority negative is
the project constraint that requires it: native module priority filtering would
otherwise hide an ordinary claim when another owner uses `mkForce`.

`negative/` isolates package and overlay leaf collisions, equal- and
mixed-priority registry ownership, reserved scope names, and non-derivation
local checks. Every failure includes the claimed key and owner/source
provenance. These are fixture facts, not a public API; the implementation
remains internal and import-only.

## Native namespaces

Package paths follow the pinned nixpkgs recursive discovery grammar. Both
`packages/ai/devTools/tool.nix` and `packages/ai/devTools/tool/package.nix`
publish `ai.devTools.tool`. Other directories are namespace containers. Case,
underscores, and literal dots are preserved; path components are never decoded
from dotted strings. The outer owner directory is independent of these package
names.

Each owner tree is realized once through native recursive discovery and nested
scopes. The `alpha` fixture depends on both a sibling and an ancestor-visible
package. Distinct owners extend `ai.devTools`, and the root derives the package
overlay from the resulting tree before applying ordinary owner overlays. The
package projection contains derivations and namespace containers only.

Platform omission uses a filtered source view because native discovery has no
platform predicate. Unsupported leaves never enter the native scopes. Recipes
are called at their original paths, preserving relative source imports and
package identity. The platform-negative recipe throws if accidentally forced.
The same owner has a supported recipe that reads a local sidecar and imports
outside its package tree; its native, projected, and overlaid derivations match
a direct call at the original path.

Negative fixtures cover duplicate leaves, leaf/container conflicts in both
orders, reserved names at nested depths (including explicit scope arguments),
and ordinary overlays attempting to claim generated package leaves or either
conflicting prefix. Owner overlays return only the leaves they claim: `alpha`
adds `ai.devTools.alpha-note` beside the `alpha-tool` derivation. The
`overlay-sparse` and `overlay-re-emit` scenarios run against a sibling
derivation whose `outPath` aborts: the sparse shape never forces it, and the
re-emitting shape still passes the claims check beside a plain sibling but
forces the aborting one. A prior derivation at a generated package leaf is
replaced whole, while neighboring namespace contents survive. The former
uppercase-name and empty-namespace negative fixtures are now positive controls:
native discovery accepts both.

## Native check composition

The namespace peer imports a private check module that consumes a native
`_module.args` value and merged `testing.moduleProbes`. This proves owner check
entries participate in the module system. Equal-priority and mixed-priority
owner collisions fail before overrides can hide ownership. A separate root/root
control proves workspace modules have the same exclusive boundary. The real
git-revise relocation check also exercises a root/owner collision.
