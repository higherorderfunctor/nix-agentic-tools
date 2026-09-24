# The activation merge must not widen a credential file.
#
# The shared-document writer (`lib/ai/own.py`, reached through the delivery
# router) reconciles Nix-declared leaves into files the runtime itself writes
# secrets into — `.claude.json` carries account tokens, kimchi's `config.json`
# carries `apiKey` and `gitTokens`. Its predecessor ended with a hardcoded
# `chmod 644`, which was the ONLY thing making those files group- and
# world-readable, on every activation, with nothing failing. The cases live in
# settings-mode.py; this file hands it the store paths it drives.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # The merge writer only touches a document while it declares a leaf. So
  # render the REAL modules with both declarations empty and run what
  # activation would then run. Assert that they really are empty, or a later
  # default that fills one would turn the gate-closed case into a merge test.
  gateClosed = harness.evalHm {
    ai.claude = {
      enable = true;
      unpinLaunchEffort = lib.mkForce {};
    };
    ai.kimchi.enable = true;
  };
  kimchiConfig = "${gateClosed.config.ai.kimchi.configDir}/config.json";
  closed = runtime: path:
    lib.assertMsg ((harness.ownedDocument runtime path gateClosed).value == {})
    "ai-activation-settings-mode: ai.${runtime} declares leaves into ${path}; the gate-closed case no longer tests a closed gate";
  gateClosedScript = assert closed "claude" ".claude.json";
  assert closed "kimchi" kimchiConfig;
    pkgs.writeText "activation-gate-closed.sh" (lib.concatMapStrings
      (name: gateClosed.config.home.activation.${name}.text + "\n")
      ["claudeUnpinLaunchEffort" "claudeConfigMode" "kimchiConfigMerge" "kimchiConfigMode"]);

  tools = {
    bash = "${pkgs.bash}/bin/bash";
    gateClosed = "${gateClosedScript}";
    inherit kimchiConfig;
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
