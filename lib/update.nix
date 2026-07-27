# lib/update.nix — the option declaration for the update-target registry.
#
# This module declares `options.update.targets` (and the sibling
# `options.update.excludePatterns`). It is the single source of truth for
# per-package update config: `config/update-matrix.nix` was dissolved into
# `config.update.targets`, so there is no longer a parallel matrix to keep in
# sync. Every package contributes its own row:
#
#   - the 20 non-effect-mcp packages via config/update-targets.nix
#   - effect-mcp via its co-located overlays/mcp-servers/effect-mcp.update.nix
#
# `lib.evalModules` merges those contributions and does the collision-checking;
# the result is exposed as the `.#updateTargets` flake output, read by both the
# ninja generator (config/generate-update-ninja.nix) and update-pkg.sh.
#
# Mirrors the authoring style of lib/ai/sharedOptions.nix and the reference
# submodule shape of the sibling option-merged registries
# lib/fragments-registry.nix and lib/checks.nix. This line used to cite
# private/slice-fixture/lib/concerns.nix; /private/ is gitignored local working
# material, so that pointer resolved for nobody but its author (the fixture is
# described in docs/package-restructure.md).
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.update.targets = mkOption {
    default = {};
    description = ''
      Merged update-target registry — the single source of truth for
      per-package update config. Each attribute names one package; a
      slice/package declares its own entry via config.update.targets.<name>.
    '';
    type = types.attrsOf (types.submodule {
      options = {
        file = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Overlay/source file to rev-bump, as a repo-relative POSIX path
            STRING (never a Nix path literal). For main-tracking packages it
            must equal the tail that resolve_overlay_file prints for this
            package's upstream, so the declared path and the resolver stay
            byte-identical — enforced by checks/update-targets-parity.nix.
            `null` for binary (--use-update-script) packages, which self-manage
            their sources and have no single overlay file to sed-bump.
          '';
        };
        flags = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Extra nix-update CLI flags, e.g. ["--version" "skip"]. Emitted
            space-joined into the ninja DAG (config/generate-update-ninja.nix)
            and consumed positionally by update-pkg.sh.
          '';
        };
        git = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Upstream repo URL for main-tracking rev-bump; null for binary
            (--use-update-script) packages.
          '';
        };
        dependsOn = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            DAG predecessors, e.g. ["rust-overlay"]. The ninja generator turns
            each entry <d> into an `update-<d>` edge, ordered after the
            universal baseDeps (update-nixpkgs, update-nix-update).
          '';
        };
      };
    });
  };

  options.update.excludePatterns = mkOption {
    type = types.listOf types.str;
    default = [];
    description = ''
      Regex patterns (matched against flake package names) excluded from the
      update loop. Currently declared-but-unconsumed — preserved from the
      dissolved matrix as its merge-up home.
    '';
  };
}
