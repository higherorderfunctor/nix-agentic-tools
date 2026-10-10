# The rendered launcher must carry runtime project trust into both Codex and
# the preflight, without writing persistent user trust.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  stub = pkgs.writeScriptBin "codex" ''
    #!${pkgs.python3}/bin/python3
    import json, sys
    print(json.dumps(sys.argv[1:]))
  '';
  launcher = package: trustProjectForSession: "${lib.head
    (harness.evalDevenv {
      ai.codex = {
        enable = true;
        inherit package trustProjectForSession;
      };
    }).config.packages}/bin/codex";
in {
  checks = {
    chatgpt-codex-session-trust = pkgs.runCommand "chatgpt-codex-session-trust" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 ${./session-trust-test.py} \
        ${lib.escapeShellArgs [(launcher stub false) (launcher stub true) (launcher harness.aiStubs.chatgpt-codex false) (launcher harness.aiStubs.chatgpt-codex true)]}
      echo PASS > "$out"
    '';
    module-codex-session-trust-hm-unknown-option = harness.mkTest "codex-session-trust-hm-unknown-option" (!(builtins.tryEval (builtins.deepSeq
      (harness.evalHm {ai.codex.trustProjectForSession = true;}).config
      true)).success);
  };
}
