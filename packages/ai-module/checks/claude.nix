# Execute Claude's HM document, legacy drain and ordered mode repair.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  dagLib = import ./dag-lib.nix harness.hmLib;
  legacy = {
    codec = "json";
    ledger = "json-settings/claude-unpin-launch-effort.json";
    path = ".claude.json";
  };
  never = (harness.evalHm {}).config;
  devenv = (harness.evalDevenv {ai.claude.enable = true;}).config;
  declarations = [
    {
      first = true;
      second = true;
    }
    {second = false;}
    {}
  ];
  fixture = map (settings: let
    evaluate = enable:
      (harness.evalHmWithSpecialArgs {lib = dagLib;} {
        ai = {
          claude = {
            inherit enable;
            unpinLaunchEffort = lib.mkForce settings;
          };
          gitSshConfigWorkaround = false;
        };
      }).config;
    enabled = evaluate true;
    disabled = evaluate false;
    generate = config: let
      plan = files.normalize {
        backend = "hm";
        files = config.ai.files2;
        namespace = "ai";
        owners = config.ai.files2Owners;
      };
    in {
      inherit plan;
      planFile = "${pkgs.writeText "files2-ai-plan.json" (builtins.toJSON plan)}";
      scripts = map (key: config.home.activation.${key}.text) (builtins.filter (key: config.home.activation ? ${key}) ["ai2-files2-prune" "ai2-files2-apply"]);
      mode = config.home.activation.ai2-claude-config-mode.text or "";
    };
  in
    assert if settings == {}
    then !(enabled.ai.files2 ? ".claude.json")
    else enabled.ai.files2.".claude.json".method == "rw" && enabled.ai.files2.".claude.json".content.value == settings;
    assert lib.all (config: config.ai.claude.legacyLedgers == [legacy] && builtins.elem legacy config.ai.legacyLedgers) [enabled disabled never];
    assert !(disabled.ai.files2 ? ".claude.json") && !(devenv.ai.files2 ? ".claude.json");
    assert !(disabled.home.activation ? ai2-claude-config-mode) && !(devenv.tasks ? "ai2:claude-config-mode");
    # Old mode and unpin entries both followed linkGeneration (the default
    # writer.after). Materialized keeps that edge and adds apply -> mode.
    assert enabled.ai.claude.activation2.claude-config-mode.after == ["materialized"];
    assert enabled.home.activation.ai2-claude-config-mode.after == ["ai2-files-ready"];
    # An empty flag map has no plan: prune retires prior flags without apply.
    assert disabled.home.activation ? ai2-files2-prune && !(disabled.home.activation ? ai2-files2-apply);
    assert enabled.home.activation ? ai2-files2-prune;
    assert if settings == {}
    then !(enabled.home.activation ? ai2-files2-apply)
    else builtins.elem "ai2-files-ready" enabled.home.activation.ai2-files2-apply.before; {
      inherit settings;
      disabled = generate disabled;
      enabled = generate enabled;
    })
  declarations;
  fixtureJson = builtins.toJSON {
    inherit fixture legacy;
    bash = "${pkgs.bash}/bin/bash";
  };
in {
  checks.ai-activation-settings-mode = pkgs.runCommand "ai-activation-settings-mode" {passthru = {inherit fixtureJson;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./claude.py} \
      ${pkgs.writeText "claude-activation.json" fixtureJson} ${pkgs.writeText "hm-run.sh" harness.hmRunShim}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
