# Extractor fixtures and pinned vendor-steering drift.
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
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./kiro-workflows-steering-fixtures.py} ${../lib/kiro-workflows-steering.py}
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    }
    # Linux-tested offline route; only a stamp reaches the store/cache.
    // lib.optionalAttrs isLinux {
      kiro-workflows-steering-drift = pkgs.runCommandLocal "kiro-workflows-steering-drift-check" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3=${pkgs.python3}/bin/python3
        chat=$("$python3" ${vu.kiroLocateChatScript pkgs} ${self.packages.${system}.kiro-cli.unwrapped})
        "$python3" ${../extract/embedded-tui.py} kas "$chat" "$TMPDIR/acp-server.js" \
          ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        "$python3" ${../lib/kiro-workflows-steering.py} "$TMPDIR/acp-server.js" > "$TMPDIR/steering"
        ${lib.concatMapStringsSep "\n" (anchor: ''
            echo ${lib.escapeShellArg "Checking vendor steering: ${anchor}"}
            ${pkgs.gnugrep}/bin/grep -F -- ${lib.escapeShellArg anchor} "$TMPDIR/steering" > /dev/null
          '')
          vendorAnchors}
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    };
}
