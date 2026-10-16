# The old ownership engine's private-file and concurrent-write guarantees.
{pkgs, ...}: let
  tools = {
    bash = "${pkgs.bash}/bin/bash";
    own = "${../../lib/ai/own.py}";
    python = "${pkgs.python3}/bin/python3";
  };
in {
  checks.ai-own-settings-mode = pkgs.runCommand "ai-own-settings-mode" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python3 ${./settings-mode.py} ${pkgs.writeText "own-settings-tools.json" (builtins.toJSON tools)}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
