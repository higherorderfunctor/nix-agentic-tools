{
  lib,
  pkgs,
  ...
}: let
  # mitmproxy 12.3.0's test_emudhra fails on Python 3.14.10, whose ssl module
  # rejects the compromised eMudhra intermediates the test connects through.
  # nixpkgs fixes the test in 12.3.1; until nixos-unstable ships it, skip that
  # one test. The Update workflow's annotations job warns once it has shipped.
  mitmproxy =
    if lib.versionOlder pkgs.mitmproxy.version "12.3.1"
    then pkgs.mitmproxy.overridePythonAttrs (old: {disabledTests = (old.disabledTests or []) ++ ["test_emudhra"];})
    else pkgs.mitmproxy;
in {
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
  checks.kiro-usage-mitm-transport = pkgs.runCommand "kiro-usage-mitm-transport-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python3 ${./usage-mitm-transport.py} \
      --mitmdump ${mitmproxy}/bin/mitmdump \
      --addon ${../usage}/mitm_addon.py
    touch "$out"
  '';
}
