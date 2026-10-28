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
      git-absorb = "recipe";
      git-branchless = "recipe";
      oxlint = "recipe";

      # Release sidecars need ordered source/channel/dependency repair.
      chatgpt-codex = "sidecar";
      fblog = "sidecar";
      pnpm_12 = "sidecar";
      rumdl = "sidecar";
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
    sidecars = lib.mapAttrs (name: _: declared.${name}) (lib.filterAttrs (_: destination: destination == "sidecar") present);
    orderAssertFn = import ./source-version-order.nix {
      inherit pkgs;
      dependencyFixer = "cargo";
      requireSrc = true;
      versionFixer = "rust-toolchain";
    };
    mkOrderCheck = name: p:
      pkgs.runCommand "rust-toolchain-extract-order-${name}" {
        extract = p.rustUpdateExtract;
        exportReferencesGraph = ["updateClosure" p.updateScript];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${orderAssertFn}
        assert_chain_order "$extract" "${name}"
        if ! grep -qF -- "$extract" updateClosure; then
          echo 'FAIL: ${name}: rustUpdateExtract is absent from updateScript closure' >&2
          exit 1
        fi
        echo '${name}: release updater reaches source/channel/dependency order' > "$out"
      '';
    orderControl = pkgs.runCommand "rust-toolchain-extract-order-positive-control" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${orderAssertFn}
      printf '%s\n' /fixture-fix-src-test /fixture-fix-rust-toolchain-test /fixture-fix-cargo-test >ordered
      assert_chain_order ordered control-ordered
      for stages in 'src cargo rust-toolchain' 'rust-toolchain src cargo' 'src rust-toolchain' 'rust-toolchain cargo'; do
        : >broken
        for stage in $stages; do
          printf '/fixture-fix-%s-test\n' "$stage" >>broken
        done
        if assert_chain_order broken "$stages" >diagnostic 2>&1; then
          echo "FAIL: accepted broken Rust chain: $stages" >&2
          exit 1
        fi
        grep -qF 'FAIL:' diagnostic
      done
      echo 'ordered Rust chain passes; dependency-first, source-last and missing stages fail with diagnostics' > "$out"
    '';
  in
    {
      rust-toolchain-declared-list = assert lib.assertMsg (lib.all (passed: passed) (builtins.attrValues roster)) "rust-toolchain-declared-list: update the drift roster and rustToolchainChannel metadata";
        pkgs.runCommand "rust-toolchain-declared-list" {passthru.cases = roster;} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          touch "$out"
        '';
      rust-toolchain-extract-order-positive-control = orderControl;
    }
    // lib.mapAttrs' (name: p: lib.nameValuePair "rust-toolchain-drift-${name}" (mkCheck name p)) declared
    // lib.mapAttrs' (name: p: lib.nameValuePair "rust-toolchain-extract-order-${name}" (mkOrderCheck name p)) sidecars;
}
