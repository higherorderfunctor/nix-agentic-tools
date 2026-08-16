# Tracked facet composition mock

This fixture exercises the internal production-candidate loader without
publishing any mock package, overlay, or module. The shortest useful read is:

1. [`lib/facets.nix`](../../../lib/facets.nix) for deterministic discovery and
   native composition;
2. [`compatible/alpha/`](compatible/alpha/) for one asymmetric owner; and
3. [`checks/facet-mock.nix`](../../facet-mock.nix) for root policy and
   cross-facet assertions.

`compatible/` contains three owners with deliberately different contribution
sets. Alpha owns a package, overlay, Home Manager module, local checks, and a
registry entry. Bravo owns a package, library contribution, overlay, devenv
module, local checks, and a registry entry. The third owner is the
zero-registration extension: only its own files name it, while discovery still
composes its library value, local check, and registry entry.

The `collisions/` scenarios isolate package, library, overlay, local-check, and
registry collisions so one early failure cannot mask another. The root check
also drives invalid-owner, unknown-entry, empty-owner, symlink, and false-local-
check cases through a standalone evaluator and checks their diagnostics. These
are fixture facts, not public API promises: the loader remains import-only and
the repository root retains aggregation, policy, and cross-facet assertions.
