{pkgs, ...}: let
  package = pkgs.ai.kiro-cli;
  patched = package.withBundlePatches {
    identity = "Custom identity. Another sentence!";
    replace = ["relativeFileCheckPaths" "stripVendorWorktreeSteering"];
  };
  wrap = package:
    (import ../lib/wrapPackage.nix {
      inherit pkgs;
      inherit (pkgs) lib;
    }).wrapPackage {
      inherit package;
      trustedMcpTools = [];
      useFhsSandbox = false;
      v3 = true;
    };
  variants = pkgs.writeText "kiro-cli-kas-dispatch.json" (builtins.toJSON {
    stock = {
      package = wrap package;
      server = server package.kas;
      managed = false;
    };
    patched = {
      package = wrap patched;
      server = server patched.kas;
      managed = true;
    };
  });
  server = kas: "${kas}/node_modules/@kiro/agent/dist/server/acp-server.js";
in {
  checks = {
    kiro-bundle-patch =
      pkgs.runCommandLocal "kiro-cli-bundle-patch-check" {
        nativeBuildInputs = [pkgs.nodejs pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./kiro-bundle-patch.py} ${../lib/kiro-bundle-patch.py} ${(import ../lib/packaging.nix).kiroPromptsExtractScript pkgs}
        touch "$out"
      '';
    kiro-kas-dispatch =
      pkgs.runCommandLocal "kiro-cli-kas-dispatch-check" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./kas-dispatch.py} ${variants} ${./kas-smoke.py}
        touch "$out"
      '';
    kiro-kas-extraction =
      pkgs.runCommandLocal "kiro-cli-kas-extraction-check" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./embedded-kas.py} ${../extract/embedded-kas.py} \
          ${pkgs.lib.getLib pkgs.zstd}/lib/libzstd${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} ${pkgs.zstd}/bin/zstd
        touch "$out"
      '';
    # Real release data on BOTH native builders, never a user cache or final
    # native output dependency. The selected installed tree has no stock-tree
    # reference; the check may compare both as independent build inputs.
    kiro-bundle-patch-drift =
      pkgs.runCommandLocal "kiro-cli-bundle-patch-drift-check" {
        nativeBuildInputs = [pkgs.nodejs pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${../lib/kiro-bundle-patch.py} ${server package.kas} ${package.kas.promptCorpus} --check
        python3 ${./kas-vendor-patches.py} ${../lib/kiro-bundle-patch.py} ${server package.kas} ${server patched.kas} ${package.kas.promptCorpus} ${(import ../lib/packaging.nix).kiroPromptsExtractScript pkgs}
        python3 ${./kas-smoke.py} ${pkgs.nodejs}/bin/node ${server patched.kas}
        touch "$out"
      '';
  };
}
