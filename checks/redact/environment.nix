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
  badReference = redact.command {path = toString noisy;};
  bad = packages badReference;
  # Kiro writes separate launcher scripts; inspect their emitted text at eval time.
  kiroPlan = reference:
    ((import ../../packages/kiro-cli/lib/wrapPackage.nix {
        inherit lib;
        pkgs = pkgs // {writeShellScript = _: text: text;};
      }).wrapPackage {
        environmentVariables = (configured harness.evalHm "kiro" "kiro-cli" reference).config.ai.kiro.normalized.environmentVariables;
        package = stub "kiro-cli";
        trustedMcpTools = [];
        v3 = false;
      }).buildCommand;
  plans =
    lib.mapAttrs (_: package: package.buildCommand) (good // lib.mapAttrs' (name: value: lib.nameValuePair "bad-${name}" value) bad)
    // {
      bad-kiro = kiroPlan badReference;
      kiro = kiroPlan file;
    };
  referenceOnly = lib.all (text:
    lib.hasInfix "redact-read" text
    && lib.hasInfix valuePath text
    && lib.hasInfix ''REDACT_TOKEN="$('' text
    && lib.all (assignment: lib.hasPrefix ''"$('' assignment)
    (builtins.tail (lib.splitString "REDACT_TOKEN=" text)))
  (builtins.attrValues plans);
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
  checks.redact-environment = assert referenceOnly;
    pkgs.runCommand "redact-environment" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # Construct the private bytes only during the check, never in a store plan.
      sentinel="private-$(cat /proc/sys/kernel/random/uuid)"
      printf '%s\n' "$sentinel" > ${valuePath}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (runtime: exe: ''
          ${good.${runtime}}/bin/${exe} probe-argument >argv 2>diagnostics
          test "$(<argv)" = "probe-argument"
          if grep -Fq "$sentinel" argv diagnostics; then echo "leak: ${runtime} argv or diagnostics" >&2; exit 1; fi
          if ${bad.${runtime}}/bin/${exe} probe-argument >argv 2>diagnostics; then
            echo '${runtime}: noisy reference did not abort' >&2
            exit 1
          fi
          test ! -s argv
          grep -q 'ai.${runtime}.environmentVariables.REDACT_TOKEN' diagnostics
          if grep -Fq "$sentinel" diagnostics; then echo "leak: ${runtime} failed reference diagnostics" >&2; exit 1; fi
        '')
        runtimes)}
      touch "$out"
    '';
}
