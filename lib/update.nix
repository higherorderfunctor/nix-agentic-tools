# lib/update.nix — plain module declaring the merged update-target registry.
#
# COEXISTENCE: this option-based registry runs ALONGSIDE
# config/update-matrix.nix, which stays the live fallback. Only effect-mcp is
# migrated for now — the Track-A "config.update.targets merge-up" beachhead. A
# later step dissolves the matrix once every package carries a
# config.update.targets contribution and the ninja generator reads from here;
# until then update-pkg.sh prefers a declared target and falls back to
# resolve_overlay_file over the matrix. Do NOT dissolve the matrix here.
#
# Mirrors the authoring style of lib/ai/sharedOptions.nix and the reference
# submodule shape in private/slice-fixture/lib/concerns.nix. Each slice/package
# contributes its own row via config.update.targets.<name>; the module system
# does the merge and collision-checking.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.update.targets = mkOption {
    default = {};
    description = ''
      Merged update-target registry (coexists with, and will later replace,
      config/update-matrix.nix). Each attribute names one source/overlay file
      to bump for a package; a slice/package declares its own entry via
      config.update.targets.<name>.
    '';
    type = types.attrsOf (types.submodule {
      options = {
        file = mkOption {
          type = types.str;
          description = ''
            Overlay/source file to bump, as a repo-relative POSIX path STRING
            (never a Nix path literal). It must equal the tail that
            resolve_overlay_file prints for this package's upstream, so the
            declared path and the resolver stay byte-identical while the two
            resolution paths coexist. Enforced by
            checks/update-targets-parity.nix.
          '';
        };
        flags = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            Extra nix-update CLI flags, e.g. ["--version" "skip"]. Not yet
            consumed by update-pkg.sh — flags still flow positionally from
            config/update-matrix.nix via the ninja DAG during coexistence.
          '';
        };
        dependsOn = mkOption {
          type = types.listOf types.str;
          default = [];
          description = ''
            DAG predecessors, e.g. ["rust-overlay"]. Declared but unused during
            the beachhead; reserved for when the ninja generator reads edges
            from this registry instead of the matrix.
          '';
        };
      };
    });
  };
}
