{pkgs, ...}: {
  checks.kiro-usage-capture = pkgs.runCommandLocal "kiro-usage-capture-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
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
      --mitmdump ${pkgs.mitmproxy}/bin/mitmdump \
      --addon ${../usage}/mitm_addon.py
    touch "$out"
  '';
}
