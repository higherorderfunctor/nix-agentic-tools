# lib/checks.nix — the option declaration for the cache-hit-parity registry.
#
# This module declares `options.checks.cacheHitParity`. It is the single
# source of truth for which overlay packages the cache-hit-parity check
# compares across nixpkgs pins: the six hardcoded lists that used to live in
# checks/cache-hit-parity.nix (aiCliPackages, gitToolPackages, devToolPackages,
# agnixPackages, mcpServerPackages, specialPackages) were dissolved into
# `config.checks.cacheHitParity`, so there is no longer a parallel set of lists
# to keep in sync. Every package contributes its own row via
# config.checks.cacheHitParity.<name>.
#
# `lib.evalModules` merges those contributions and does the collision-checking;
# the result is exposed as the `.#cacheHitParityTargets` flake output, read by
# checks/cache-hit-parity.nix.
#
# Mirrors the authoring style of lib/update.nix.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.checks.cacheHitParity = mkOption {
    default = {};
    description = ''
      Merged cache-hit-parity registry — the single source of truth for which
      overlay packages the cache-hit-parity check compares. Each attribute
      names one package; a slice/package declares its own row via
      config.checks.cacheHitParity.<name>. The module system merges the
      contributions and the result is exposed as the `.#cacheHitParityTargets`
      flake output, consumed by checks/cache-hit-parity.nix.
    '';
    type = types.attrsOf (types.submodule {
      options.consumerPath = mkOption {
        type = types.listOf types.str;
        description = ''
          The attr-path under `consumerPkgs` where the overlay exposes this
          package to downstream consumers (e.g.
          ["ai" "mcpServers" "serena-mcp"]). The cache-hit-parity check resolves
          it with `lib.getAttrFromPath`. The standalone side is always looked up
          as `self.packages.<system>.<the attr key>`.
        '';
      };
    });
  };
}
