# Tracked production-boundary facet mock

This fixture keeps discovery separate from registry realization and publishes no
mock package, overlay, module, or library. The shortest useful read is:

1. [`lib/facets.nix`](../../../lib/facets.nix) for the system-independent index
   and registry-specific realizers;
2. [`production/git-revise/`](production/git-revise/) for a vertically owned,
   production-shaped package boundary; and
3. [`checks/facet-mock.nix`](../../facet-mock.nix) for generic orchestration and
   cross-owner assertions.

`production/` is add-only by owner. The git-revise owner contains an owner
`default.nix`, package recipe, overlay, directory-shaped Home Manager and devenv
modules, derivation-valued checks, a declarative registry contribution,
documentation, fragments, and Nix/JSON sidecars. Discovery records contribution
and metadata provenance without importing the metadata-only files. The fixture
consumer evaluates raw module paths with the native module system.

Packages use `makeScope`, `callPackage`, and `packagesFromDirectoryRecursive`;
overlays use lexical `composeManyExtensions`; declarative values use
`evalModules` with explicit types. The only custom merge is exclusive-owner
validation before those native mechanisms run. The mixed-priority negative is
the project constraint that requires it: native module priority filtering would
otherwise hide an ordinary claim when another owner uses `mkForce`.

`negative/` isolates package and overlay leaf collisions, equal- and
mixed-priority registry ownership, reserved scope names, and non-derivation
local checks. Every failure includes the claimed key and owner/source
provenance. These are fixture facts, not a public API; the implementation
remains internal and import-only.
