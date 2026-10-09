{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  codex = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.chatgpt-codex;
  preflight = import ../lib/projectDocPreflight.nix pkgs;
  hm = harness.evalHm {
    ai.codex = {
      enable = true;
      package = codex;
    };
  };
  hmLauncher = lib.head hm.config.home.packages;
  devenv = harness.evalDevenv {
    ai.codex = {
      enable = true;
      package = hmLauncher;
    };
  };
  devenvLauncher = lib.head devenv.config.packages;
  fake = pkgs.writeShellScriptBin "codex" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf '{"output":"unchanged"}\n'
    ${pkgs.coreutils}/bin/cat
    exit 23
  '';
  fakeLauncher =
    lib.head
    (harness.evalHm {
      ai.codex = {
        enable = true;
        package = fake;
        pinDaemonToPackage = false;
      };
    }).config.home.packages;
  # The shared launcher isolation around preflight checks that fail and write
  # stdout, read stdin, or hang with a child of their own.
  brokenLaunchers = lib.imap0 (index: script:
    import ../../../lib/ai/launcher.nix pkgs {
      exe = "codex";
      name = "codex-broken-preflight-${toString index}";
      package = fake;
      preflight = pkgs.writeShellScriptBin "broken-preflight" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${script}
      '';
    }) ["printf 'stdout noise\\n'; exit 1" "${pkgs.coreutils}/bin/cat" "${pkgs.coreutils}/bin/sleep 3 & wait"];
in {
  checks.chatgpt-codex-project-doc-preflight = assert devenvLauncher.launcherPackage == codex;
    pkgs.runCommand "chatgpt-codex-project-doc-preflight" {
      nativeBuildInputs = [pkgs.git pkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR/home"
      export CODEX_HOME="$HOME/.codex"
      mkdir -p "$CODEX_HOME"
      # No credentials, network or model calls in this build sandbox.
      unset OPENAI_API_KEY CODEX_API_KEY
      python3 ${./project-doc-preflight-fixtures.py} \
        ${codex}/bin/codex ${lib.getExe preflight} \
        ${hmLauncher}/bin/codex ${devenvLauncher}/bin/codex \
        ${fakeLauncher}/bin/codex ${../lib/projectDocPreflight.py} ${pkgs.bash}/bin/bash \
        ${lib.getExe (import ../lib/projectTrustNotice.nix pkgs)} \
        ${lib.getExe (import ../lib/permissionLayersNotice.nix pkgs)} \
        ${lib.concatMapStringsSep " " (launcher: "${launcher}/bin/codex") brokenLaunchers}
      echo PASS > "$out"
    '';
}
