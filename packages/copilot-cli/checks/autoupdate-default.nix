{pkgs, ...}: {
  checks.copilot-cli-autoupdate-default = pkgs.runCommand "copilot-cli-autoupdate-default" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.gnugrep}/bin/grep -qF "export COPILOT_AUTO_UPDATE=\''${COPILOT_AUTO_UPDATE-'false'}" ${pkgs.ai.copilot-cli}/bin/copilot
    ${pkgs.gnugrep}/bin/grep -aqF 'COPILOT_AUTO_UPDATE' ${pkgs.ai.copilot-cli}/libexec/copilot
    touch "$out"
  '';
}
