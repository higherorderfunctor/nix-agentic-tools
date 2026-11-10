{
  lib,
  pkgs,
  ...
}: {
  checks.kiro-usage-capture = pkgs.runCommandLocal "kiro-usage-capture-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export KIRO_LAUNCH_VALUE_OPTIONS=${lib.escapeShellArg (lib.concatStringsSep "," (import ../lib/launchValueOptions.nix {inherit lib;}).measured)}
    cp -r ${../usage} usage
    chmod -R u+w usage
    cd usage
    ${pkgs.python3}/bin/python3 -m unittest discover -v
    touch "$out"
  '';
  # Forcing this flake's patched mitmproxy (packages/kiro-cli/overlay.nix)
  # builds it, and mitmproxy derivations run their pytest suite: the unpatched
  # nixpkgs 12.3.0 build fails test_emudhra on CPython 3.13.18/3.14.10, whose
  # ssl module rejects the compromised eMudhra intermediates the test connects
  # through (https://github.com/python/cpython/issues/160040). A check that
  # selected plain `pkgs.mitmproxy` instead would fail this build here.
  checks.kiro-usage-mitm-transport = pkgs.runCommand "kiro-usage-mitm-transport-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python3 ${./usage-mitm-transport.py} \
      --mitmdump ${pkgs.ai.generic.mitmproxy}/bin/mitmdump \
      --addon ${../usage}/mitm_addon.py
    touch "$out"
  '';
}
