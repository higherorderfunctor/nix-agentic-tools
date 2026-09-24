# The activation merge must not widen a credential file.
#
# The shared-document writer (`lib/ai/own.py`, reached through the delivery
# router) reconciles Nix-declared leaves into files the runtime itself writes
# secrets into — `.claude.json` carries account tokens, kimchi's `config.json`
# carries `apiKey` and `gitTokens`. Its predecessor ended with a hardcoded
# `chmod 644`, which was the ONLY thing making those files group- and
# world-readable, on every activation, with nothing failing. The cases live in
# settings-mode.py; this file hands it the store paths it drives.
{pkgs, ...}: let
  tools = {
    bash = "${pkgs.bash}/bin/bash";
    own = "${../../lib/ai/own.py}";
    python = "${pkgs.python3}/bin/python3";
  };
in {
  checks.ai-activation-settings-mode = pkgs.runCommand "ai-activation-settings-mode" {} ''
    ${pkgs.python3}/bin/python3 ${./settings-mode.py} \
      ${pkgs.writeText "ai-activation-tools.json" (builtins.toJSON tools)}
    touch "$out"
  '';
}
