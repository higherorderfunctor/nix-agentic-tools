{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  redact = self.lib.redact;
  runtimes = {
    codex = "codex";
    copilot = "copilot";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  valuePath = "/build/redact-environment-value";
  file = redact.file {path = valuePath;};
  noisy = pkgs.writeShellScript "redact-environment-noisy" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.coreutils}/bin/cat ${valuePath}
    ${pkgs.coreutils}/bin/cat ${valuePath} >&2
    exit 1
  '';
  stub = exe:
    pkgs.writeShellScriptBin exe ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      test "$REDACT_TOKEN" = "$(<${valuePath})"
      test "$PRIVATE_HOST" = "$REDACT_TOKEN"
      test "$PUBLIC_SETTING" = "public"
      test -z "''${REMOVED+x}"
      printf '%s\n' "$@"
    '';
  configured = evaluate: runtime: exe: reference:
    evaluate {
      ai.environmentVariables = {
        PRIVATE_HOST = file;
        PUBLIC_SETTING = "root";
        REDACT_TOKEN = reference;
        REMOVED = "root";
      };
      ai.${runtime} = {
        enable = true;
        environmentVariables = {
          PUBLIC_SETTING = "public";
          REMOVED = null;
        };
        package = stub exe;
      };
    };
  packages = reference:
    lib.mapAttrs (runtime: exe:
      builtins.head (configured harness.evalHm runtime exe reference).config.home.packages)
    runtimes;
  good = packages file;
  bad = packages (redact.command {path = toString noisy;});
  plans = pkgs.writeText "redact-environment-plans.json" (builtins.toJSON (lib.mapAttrs (_: package: package.buildCommand) (good // lib.mapAttrs' (name: value: lib.nameValuePair "bad-${name}" value) bad)));
in {
  checks.redact-environment-modules = harness.mkTest "redact-environment-modules" (
    lib.all (evaluate:
      lib.all (runtime: let
        evaluated = configured evaluate runtime runtimes.${runtime} file;
        pool = evaluated.config.ai.${runtime}.normalized.environmentVariables;
      in
        pool.REDACT_TOKEN
        == file
        && pool.PRIVATE_HOST == file
        && pool.PUBLIC_SETTING == "public"
        && !(pool ? REMOVED))
      (builtins.attrNames runtimes)) [harness.evalHm harness.evalDevenv]
  );
  checks.redact-environment = pkgs.runCommand "redact-environment" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # Construct the private bytes only during the check, never in a store plan.
    sentinel="private-$(printf '%s' 'environment-value')"
    printf '%s\n' "$sentinel" > ${valuePath}
    ! grep -Fq "$sentinel" ${plans}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (runtime: exe: ''
        ! grep -RFq "$sentinel" ${good.${runtime}}/bin ${bad.${runtime}}/bin
        ${good.${runtime}}/bin/${exe} probe-argument >argv 2>diagnostics
        test "$(<argv)" = "probe-argument"
        ! grep -Fq "$sentinel" argv diagnostics
        if ${bad.${runtime}}/bin/${exe} probe-argument >argv 2>diagnostics; then
          echo '${runtime}: noisy reference did not abort' >&2
          exit 1
        fi
        test ! -s argv
        grep -q 'REDACT_TOKEN' diagnostics
        ! grep -Fq "$sentinel" diagnostics
      '')
      runtimes)}
    touch "$out"
  '';
}
