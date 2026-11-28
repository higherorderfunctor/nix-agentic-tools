{
  harness,
  pkgs,
  ...
}: let
  package = pkgs.ai.kiro-cli;
  replace = ["relativeFileCheckPaths"];
  # Read the routing module's production edit, not a fixture copy.
  routed =
    (harness.evalHm {
      ai.kiro.cli = {
        enable = true;
        inherit package;
        workflows.enable = true;
      };
      ai.programs.delegate-routing = {
        enable = true;
        runtimes.kiro.models = [{vendors = ["anthropic"];}];
      };
    }).config.ai.kiro.cli;
  routingEdit = routed.prompts.allowWorktreeCreation;
  routedKas =
    (package.withBundlePatches {
      replace = builtins.attrNames (pkgs.lib.filterAttrs (_: enabled: enabled) routed.tweaks);
      prompts.allowWorktreeCreation = assert routingEdit.enable; {inherit (routingEdit) match replace target;};
    }).kas;
  patched = package.withBundlePatches {
    inherit replace;
    sessionRoots = ["additionalDirectories"];
  };
  wrap = package:
    (import ../lib/wrapPackage.nix {
      inherit pkgs;
      inherit (pkgs) lib;
    }).wrapPackage {
      inherit package;
      useFhsSandbox = false;
    };
  # `unwrapped` is the stock payload the raw argv measurement runs against.
  variants = pkgs.writeText "kiro-cli-kas-dispatch.json" (builtins.toJSON {
    stock = {
      package = wrap package;
      server = server package.kas;
      managed = false;
      unwrapped = "${package.unwrapped}";
    };
    patched = {
      package = wrap patched;
      server = server patched.kas;
      managed = true;
    };
  });
  server = kas: "${kas}/node_modules/@kiro/agent/dist/server/acp-server.js";
  extractPrompts = (import ../lib/packaging.nix).kiroPromptFactsExtractScript pkgs;
in {
  checks = {
    kiro-bundle-patch =
      pkgs.runCommandLocal "kiro-cli-bundle-patch-check" {
        nativeBuildInputs = [pkgs.nodejs pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./kiro-bundle-patch.py} ${../lib/kiro-bundle-patch.py}
        touch "$out"
      '';
    # The session-roots patch on the pinned bundle, run against the real vendor
    # functions it touches.
    kiro-additional-roots =
      pkgs.runCommandLocal "kiro-cli-additional-roots-check" {
        nativeBuildInputs = [pkgs.nodejs];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        node ${./additional-roots.mjs} ${server package.kas} ${pkgs.typescript_5}/lib/node_modules/typescript ${../src}
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
    # The prompt extractor on synthetic bundles, then on the pinned real one.
    kiro-prompt-extract =
      pkgs.runCommandLocal "kiro-cli-prompt-extract-check" {
        nativeBuildInputs = [pkgs.nodejs];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        node ${./prompt-extract.mjs} ${pkgs.typescript_5}/lib/node_modules/typescript ${server package.kas} ${../extract/prompts.mjs}
        touch "$out"
      '';
    # The per-session fill on the pinned bundle: both readers, several checkouts.
    kiro-session-prompts =
      pkgs.runCommandLocal "kiro-cli-session-prompts-check" {
        nativeBuildInputs = [pkgs.git pkgs.nodejs pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        node ${./session-prompts.mjs} ${server package.kas} ${pkgs.typescript_5}/lib/node_modules/typescript \
          ${../lib/kiro-bundle-patch.py} ${../extract/prompts.mjs} ${../src}
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
        ${extractPrompts} ${server package.kas} > stock-leaves.json
        python3 ${../lib/kiro-bundle-patch.py} ${server package.kas} stock-leaves.json --check
        python3 ${./kas-vendor-patches.py} ${../lib/kiro-bundle-patch.py} ${server package.kas} stock-leaves.json \
          ${extractPrompts} ${package.kas} ${routedKas}
        python3 ${./kas-smoke.py} ${pkgs.nodejs}/bin/node ${server routedKas}
        touch "$out"
      '';
  };
}
