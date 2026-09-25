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
  # `own.py` creates a document 0600 and then keeps whatever mode it finds,
  # whether or not it rewrites the file. So nothing in the merge ever narrows
  # a file an earlier generation widened to 0644; the credential mode writers
  # are the only thing that does, in both gate states. Each state renders the
  # REAL modules and runs what activation would run:
  #
  #   open    a non-empty declaration, the default for every Claude user
  #           (`unpinLaunchEffort` defaults to a non-empty map): the merge
  #           rewrites the file and keeps its 0644.
  #   closed  both declarations forced empty: the merge touches nothing.
  #
  # A mode writer gated on either state fails the other one.
  gates = {
    closed = {
      evaluated = harness.evalHm {
        ai.claude = {
          enable = true;
          unpinLaunchEffort = lib.mkForce {};
        };
        ai.kimchi.enable = true;
      };
      holds = declared: declared == {};
    };
    open = {
      evaluated = harness.evalHm {
        ai.claude.enable = true;
        ai.kimchi = {
          enable = true;
          native.settings.telemetry.enabled = false;
        };
      };
      holds = declared: declared != {};
    };
  };
  entries = ["claudeUnpinLaunchEffort" "claudeConfigMode" "kimchiConfigMerge" "kimchiConfigMode"];

  # `{documents, script}`: what each writer declares into its credential
  # document, keyed by path, and the activation entries in `entries`.
  gate = name: {
    evaluated,
    holds,
  }: let
    documents = [
      {
        path = ".claude.json";
        runtime = "claude";
      }
      {
        path = "${evaluated.config.ai.kimchi.configDir}/config.json";
        runtime = "kimchi";
      }
    ];
    # Assert the declaration really is in the state the case names, or a later
    # default would silently turn one case into the other.
    declared = {
      path,
      runtime,
    }: let
      inherit (harness.ownedDocument runtime path evaluated) value;
    in
      assert lib.assertMsg (holds value)
      "ai-activation-settings-mode: ai.${runtime}'s declaration into ${path} no longer holds the gate-${name} state"; value;
    text = entry:
      (evaluated.config.home.activation.${entry}
        or (throw "ai-activation-settings-mode: the gate-${name} config renders no ${entry} activation entry; a credential mode writer must not be gated on the declaration"))
      .text;
  in {
    documents = lib.listToAttrs (map (document: lib.nameValuePair document.path (declared document)) documents);
    # Every entry here is an HM activation entry, so the assembled script needs
    # home-manager's `run` helper in scope before any of their bodies run.
    script = "${pkgs.writeText "activation-gate-${name}.sh" (harness.hmRunShim + lib.concatMapStrings (entry: text entry + "\n") entries)}";
  };

  tools = {
    bash = "${pkgs.bash}/bin/bash";
    gates = lib.mapAttrs gate gates;
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
