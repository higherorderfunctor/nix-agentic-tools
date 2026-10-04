# The vendor workflow-steering extractor behind
# ai.kiro.workflowReminder.includeVendorSteering, and the vendor text the
# default reminder is written against.
{
  lib,
  pkgs,
  self,
  ...
}: let
  vu = import ../lib/packaging.nix;
  inherit (import ../lib/workflowReminder.nix {inherit lib pkgs;}) vendorAnchors;
  inherit (pkgs.stdenv.hostPlatform) isLinux system;
in {
  checks =
    {
      kiro-workflows-steering-fixtures = pkgs.runCommandLocal "kiro-workflows-steering-fixtures-check" {} ''
        ${pkgs.python3}/bin/python3 ${./kiro-workflows-steering-fixtures.py} ${../lib/kiro-workflows-steering.py}
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    }
    # Linux only, deliberately. The route (a dummy KIRO_API_KEY plus
    # `acp --agent-engine v3`, which unpacks KAS without a login or the
    # network) was measured on Linux. The Darwin binary comes from a DMG and was
    # never tried, and `nix flake check` -- the required `test` context that
    # every update PR runs -- evaluates x86_64-linux only, so a Linux gate loses
    # no coverage of that gate. The engine bundle is platform-independent
    # JavaScript, so one platform answers the drift question.
    #
    # The output is a stamp only. The proprietary steering text never lands in
    # the store, so nothing here can reach the public cache.
    // lib.optionalAttrs isLinux {
      kiro-workflows-steering-drift =
        pkgs.runCommandLocal "kiro-workflows-steering-drift-check" {
          anchors = builtins.toJSON vendorAnchors;
          passAsFile = ["anchors"];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3=${pkgs.python3}/bin/python3
          chat=$("$python3" ${vu.kiroLocateChatScript pkgs} ${self.packages.${system}.kiro-cli.unwrapped})
          "$python3" ${../extract}/kas-bundle.py "$chat" "$TMPDIR/acp-server.js" \
            ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          "$python3" ${./kiro-workflows-steering-anchors.py} ${../lib/kiro-workflows-steering.py} \
            "$TMPDIR/acp-server.js" "$anchorsPath"
          ${pkgs.coreutils}/bin/touch "$out"
        '';
    };
}
