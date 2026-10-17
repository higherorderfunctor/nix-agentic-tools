{
  harness,
  lib,
  pkgs,
  ...
}: let
  featureWarning = declaration:
    (harness.evalDevenv {
      ai.kiro.cli = {enable = true;} // declaration;
    }).config.enterShell;
  redact = import ../../lib/redact {inherit lib;};
  stubBin = pkgs.writeShellScript "kiro-warning-stub" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf 'launched\n'
  '';
  stub = pkgs.runCommand "kiro-warning-stub-package" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${stubBin} "$out/bin/kiro-cli"
    ln -s ${stubBin} "$out/bin/kiro-cli-chat"
  '';
  wrap = secretEnv:
    (import ../../packages/kiro-cli/lib/wrapPackage.nix {inherit lib pkgs;}).wrapPackage {
      package = stub;
      v3 = false;
      trustedMcpTools = [];
      inherit secretEnv;
      secretOptionPaths.PROBE = "ai.kiro.mcpServers.probe.headers.Authorization";
    };
  wrappers = pkgs.writeText "credential-warning-wrappers.json" (builtins.toJSON {
    absent = wrap {};
    empty = wrap {PROBE = redact.command "${pkgs.coreutils}/bin/true";};
    failed = wrap {PROBE = redact.command "${pkgs.coreutils}/bin/false";};
    good = wrap {
      PROBE = redact.command (toString (pkgs.writeShellScript "test-credential" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'fixture-token'
      ''));
    };
    missing = wrap {PROBE = redact.file "/definitely-missing-ai-warning-test-secret";};
  });
in {
  checks.ai-warnings-runtime =
    pkgs.runCommand "ai-warnings-runtime" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq pkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python ${./runtime.py} \
        ${../../packages/kiro-cli/lib/global-feature-notice.py} \
        ${../../packages/claude-code/lib/memory-collision-guard.sh} \
        ${wrappers}
      touch "$out"
    '';
  checks.ai-warnings-kiro-feature-wired = harness.mkTest "ai-warnings-kiro-feature-wired" (
    lib.hasInfix "workflows" (featureWarning {
      workflows.enable = true;
      v3 = true;
    })
    && !(lib.hasInfix "global-feature" (featureWarning {
      features.workflows.enable = true;
      v3 = true;
    }))
    && lib.hasInfix "codeToSpec" (featureWarning {
      codeToSpec.enable = true;
      v3 = true;
    })
    && !(lib.hasInfix "global-feature" (featureWarning {
      features.c2s.enable = true;
      v3 = true;
    }))
    && !(lib.hasInfix "workflows" (featureWarning {}))
  );
}
