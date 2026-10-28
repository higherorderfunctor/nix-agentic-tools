# Compare recorded Rust channels with the actual crate/workspace source files.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    vu = import ../../lib/packaging.nix;
    pkgSet = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
    # Keep check-name discovery independent of package/compiler evaluation.
    destinations = {
      # Recipe literals are refreshed by revision/input update workers.
      agnix = "recipe";
      agnix-lsp = "recipe";
      agnix-mcp = "recipe";
      airlock = "recipe";
      ci-hestia = "recipe";
      fblog = "recipe";
      git-absorb = "recipe";
      git-branchless = "recipe";
      oxlint = "recipe";
      rumdl = "recipe";

      # Release sidecars need ordered source/channel/dependency repair.
      chatgpt-codex = "sidecar";
      pnpm_12 = "sidecar";
    };
    present = lib.filterAttrs (name: _: builtins.hasAttr name pkgSet) destinations;
    declared = lib.mapAttrs (name: _: pkgSet.${name}) present;
    discovered = lib.filterAttrs (_: p: p ? cargoDeps) pkgSet;
    roster = {
      "every Rust cargoDeps package has a drift check" = builtins.attrNames declared == builtins.attrNames discovered;
      "every Rust package has its declared channel writer" = lib.all (name: (declared.${name}.fixRustToolchain.rustToolchainDestination or null) == present.${name}) (builtins.attrNames present);
      "every Rust package records a channel or its absence" = lib.all (p: p ? rustToolchainChannel) (builtins.attrValues declared);
    };
    mkCheck = name: p:
      pkgs.runCommand "rust-toolchain-drift-${name}" {
        inherit (p) src;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${vu.rustToolchainFn {inherit pkgs;}}
        actual=$(rust_channel_of "$src/${p.rustToolchainRoot or "."}")
        recorded=${lib.escapeShellArg (p.rustToolchainChannel or "")}
        if [ "$actual" != "$recorded" ]; then
          echo "FAIL: ${name}: recorded Rust channel '$recorded' differs from source '$actual'" >&2
          echo 'Run ${name}.fixRustToolchain; remove a recipe override if upstream now declares a numeric version.' >&2
          exit 1
        fi
        echo "${name}: source channel '$actual' matches recorded channel" > "$out"
      '';
  in
    {
      rust-toolchain-declared-list = assert lib.assertMsg (lib.all (passed: passed) (builtins.attrValues roster)) "rust-toolchain-declared-list: update the drift roster and rustToolchainChannel metadata";
        pkgs.runCommand "rust-toolchain-declared-list" {passthru.cases = roster;} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          touch "$out"
        '';
    }
    // lib.mapAttrs' (name: p: lib.nameValuePair "rust-toolchain-drift-${name}" (mkCheck name p)) declared;
}
