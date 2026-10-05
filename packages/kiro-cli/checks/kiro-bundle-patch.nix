{
  lib,
  pkgs,
  ...
}: let
  vu = import ../lib/packaging.nix;
  materializer = import ../lib/identityBundle.nix {inherit lib pkgs;};
  identity = "Custom identity. Another sentence!";
  stubBin = pkgs.writeShellScript "kiro-bundle-launch-stub" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf 'launched:%s\n' "''${KIRO_KAS_SERVER_PATH:-stock}"
  '';
  stub = pkgs.runCommand "kiro-bundle-launch-stub-package" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${stubBin} "$out/bin/kiro-cli"
    ln -s ${stubBin} "$out/bin/kiro-cli-chat"
  '';
  launchers = pkgs.writeText "kiro-bundle-patch-launchers.json" (builtins.toJSON (
    lib.mapAttrs (_: bundleMaterializer: {
      materializer = lib.getExe bundleMaterializer;
      wrapper = (import ../lib/wrapPackage.nix {inherit lib pkgs;}).wrapPackage {
        inherit bundleMaterializer;
        package = stub;
        trustedMcpTools = [];
        v3 = false;
      };
    }) {
      both = materializer {
        cliVersion = "1.0.0";
        inherit identity;
        stripVendorWorktreeSteering = true;
      };
      worktree = materializer {
        cliVersion = "1.0.0";
        stripVendorWorktreeSteering = true;
      };
    }
  ));
in {
  checks =
    {
      kiro-bundle-patch =
        pkgs.runCommandLocal "kiro-bundle-patch-check" {
          nativeBuildInputs = [pkgs.nodejs pkgs.python3];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 ${./kiro-bundle-patch.py} ${../lib/kiro-bundle-patch.py} ${launchers}
          touch "$out"
        '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      kiro-bundle-patch-drift = pkgs.runCommandLocal "kiro-bundle-patch-drift-check" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3=${pkgs.python3}/bin/python3
        chat=$("$python3" ${vu.kiroLocateChatScript pkgs} ${pkgs.ai.kiro-cli.unwrapped})
        "$python3" ${../extract/embedded-tui.py} kas "$chat" "$TMPDIR/acp-server.js" \
          ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        "$python3" ${../lib/kiro-bundle-patch.py} "$TMPDIR/acp-server.js" --check
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    };
}
