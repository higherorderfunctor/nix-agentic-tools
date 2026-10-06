{
  lib,
  pkgs,
  self,
  ...
}: {
  imports = [./fetch-hugging-face-model.nix ./go-floor-drift.nix ./go-floor-extract-order.nix ./go-floor-fixer.nix ./go-toolchain-floor.nix ./nat-overlay-parity.nix ./pnpm-fetcher-contract.nix ./pnpm-fetcher-parity.nix ./toolchain-provenance.nix ./update-script-executable.nix ./update-target-meta-eval.nix ./update-targets-parity.nix];

  # Splits update-target rows by whether this system's `ciPackages` carries
  # them: the set update-pkg.sh points nix-update at. `present` keeps the
  # rows, `absent` is the names of the rest.
  _module.args.splitUpdateTargets = targets: let
    packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
    parts = lib.partition (name: packages ? ${name}) (builtins.attrNames targets);
  in {
    present = lib.getAttrs parts.right targets;
    absent = parts.wrong;
  };
}
