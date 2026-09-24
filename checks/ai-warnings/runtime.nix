{
  harness,
  lib,
  pkgs,
  ...
}: let
  reminder = (import ../../packages/kiro-cli/lib/workflowReminder.nix {inherit lib pkgs;}).mkVendorReminder {cliVersion = "1.0.0";};
  enabled = harness.evalDevenv {
    ai.codex = {
      enable = true;
      files."probe".content.text = "probe";
      native.settings.model = "probe";
    };
    ai.kiro = {
      configDir = ".custom-kiro";
      # A second shared-owner key. Codex contributes AGENTS.md, Kiro this one;
      # each must be attributed to the runtime whose context it is.
      context = {
        filename = "KIRO.md";
        text = "kiro probe";
      };
      enable = true;
      lspServers.probe.command = "probe";
    };
    # Consumer-declared, inside a runtime's own config directory. The delivery
    # manifest must not claim it.
    files.".custom-kiro/consumer-owned.md".text = "consumer";
  };
  # Kimchi's context.filename names the Home Manager harness file only; devenv
  # always writes the project-root AGENTS.md. Evaluated alone so no other
  # runtime's AGENTS.md writer can stand in for Kimchi's.
  kimchi = harness.evalDevenv {
    ai.kimchi = {
      context = {
        filename = "custom.md";
        text = "kimchi probe";
      };
      enable = true;
    };
  };
  stubBin = pkgs.writeShellScript "kiro-warning-stub" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf 'launched\n'
  '';
  stub = pkgs.runCommand "kiro-warning-stub-package" {} ''
    mkdir -p "$out/bin"
    ln -s ${stubBin} "$out/bin/kiro-cli"
    ln -s ${stubBin} "$out/bin/kiro-cli-chat"
  '';
  wrap = secretEnv:
    (import ../../packages/kiro-cli/lib/wrapPackage.nix {inherit lib pkgs;}) {
      package = stub;
      v3 = false;
      trustedMcpTools = [];
      inherit secretEnv;
      secretOptionPaths.PROBE = "ai.kiro.mcpServers.probe.headers.Authorization";
    };
  wrappers = pkgs.writeText "credential-warning-wrappers.json" (builtins.toJSON {
    absent = wrap {};
    empty = wrap {PROBE.file = pkgs.writeText "empty-credential" "";};
    failed = wrap {PROBE.helper = "${pkgs.coreutils}/bin/false";};
    good = wrap {PROBE.file = pkgs.writeText "test-credential" "fixture-token";};
    missing = wrap {PROBE.file = "/definitely-missing-ai-warning-test-secret";};
  });
in {
  checks.ai-warnings-runtime =
    pkgs.runCommand "ai-warnings-runtime" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq pkgs.python3];
    } ''
      ${pkgs.python3}/bin/python ${./runtime.py} \
        ${../../lib/ai/file-warnings.py} \
        ${../../packages/claude-code/lib/memory-collision-guard.sh} \
        ${lib.getExe reminder} \
        ${wrappers} \
        ${../../packages/claude-code/lib/delegation-clamp.sh} \
        ${pkgs.writeText "warning-observer-shell" enabled.config.enterShell} \
        ${pkgs.writeText "kimchi-warning-observer-shell" kimchi.config.enterShell}
      touch "$out"
    '';
  checks.ai-warnings-files-wired = harness.mkTest "ai-warnings-files-wired" (
    lib.hasInfix "file-warnings.py" enabled.config.enterShell
    && enabled.config.tasks."ai:delivery:observe-retired".before == ["devenv:files:cleanup"]
  );
}
