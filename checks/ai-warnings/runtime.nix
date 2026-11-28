{
  harness,
  lib,
  pkgs,
  ...
}: let
  # builtins.match (inside lib.hasInfix) rejects a pattern carrying store-path
  # context, so compare the path as plain text.
  featureNotice = builtins.unsafeDiscardStringContext "${../../packages/kiro-cli/lib/global-feature-notice.py}";
  inherit (harness) checkRows;
  featureWarning = declaration:
    (harness.evalDevenv {
      ai.kiro.cli = {enable = true;} // declaration;
    }).config.enterShell;
  commandText = declaration:
  # Keep command boundaries while joining shell continuation lines.
    lib.concatStringsSep " " (lib.filter builtins.isString (builtins.split "[ \t]*\\\\\n[ \t]*" (featureWarning declaration)));
  noticePrefix = "${featureNotice} \"\${KIRO_HOME:-$HOME/.kiro}\"";
  invokesNotice = feature: setting: declaration:
    lib.hasInfix "${noticePrefix} ${lib.escapeShellArg feature} ${lib.escapeShellArg setting}" (commandText declaration);
  noNotice = declaration: !lib.hasInfix featureNotice (featureWarning declaration);
  redact = import ../../lib/redact {inherit lib;};
  stubBin = pkgs.writeShellScript "kiro-warning-stub" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    case "''${PROBE-}" in
      "") printf 'launched\n' ;;
      fixture-token) printf 'launched with credential\n' ;;
      *) exit 1 ;;
    esac
  '';
  stub = pkgs.runCommand "kiro-warning-stub-package" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${stubBin} "$out/bin/kiro-cli"
  '';
  wrap = secretEnv:
    (import ../../packages/kiro-cli/lib/wrapPackage.nix {inherit lib pkgs;}).wrapPackage {
      package = stub;
      inherit secretEnv;
      secretOptionPaths.PROBE = "ai.kiro.mcpServers.probe.headers.Authorization";
    };
  wrappers = pkgs.writeText "credential-warning-wrappers.json" (builtins.toJSON {
    absent = wrap {};
    empty = wrap {PROBE = redact.command "${pkgs.coreutils}/bin/true";};
    failed = wrap {
      PROBE = redact.command (toString (pkgs.writeShellScript "failed-credential" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'partial-secret'
        printf 'helper diagnostic with private data' >&2
        exit 1
      ''));
    };
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
    checkRows "Kiro devenv feature notices" {
      "code-to-spec names the global chat.enableC2s setting" = invokesNotice "codeToSpec" "chat.enableC2s" {codeToSpec.enable = true;};
      "no friendly features means no notice" = noNotice {};
      "rollout flag alone is quiet" = noNotice {features.c2s.enable = true;};
      "workflows names the global chat.enableWorkflows setting" = invokesNotice "workflows" "chat.enableWorkflows" {workflows.enable = true;};
    }
  );
}
