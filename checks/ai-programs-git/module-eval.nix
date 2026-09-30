{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
  rv = import ../../lib/runtime-values {inherit lib;};
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  exes = {
    claude = "claude";
    codex = "codex";
    copilot = "copilot";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  stub = exe:
    pkgs.writeShellScriptBin exe ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exit 0
    '';
  launcherRuntimes = lib.remove "claude" harnessNames;
  ghDir = "/run/ai-gh";
  tokenFile = "/run/secrets/ai-github-token";
  identityWith = credentials: {
    ai =
      lib.genAttrs harnessNames (runtime: {
        enable = true;
        package = stub exes.${runtime};
        programs.git = {
          settings.user.name = "bot (${runtime})";
          signing.key = "/run/secrets/ai-${runtime}-signing-key";
        };
      })
      // {
        programs = {
          gh = {
            configDir = ghDir;
            enable = true;
          };
          git = {
            inherit credentials;
            enable = true;
            settings.user.email = "bot@example.com";
            signing = {
              format = "ssh";
              signByDefault = true;
            };
          };
        };
      };
  };
  identity = identityWith (rv.file {path = tokenFile;});
  channel = evaluated: runtime: evaluated.config.ai.${runtime}.internal._moduleEnvironmentVariables;
  failures = evaluated:
    map (entry: entry.message)
    (builtins.filter (entry: !entry.assertion) evaluated.config.assertions);
  programFailures = evaluated: builtins.filter (lib.hasInfix ".programs.g") (failures evaluated);
  gitFailures = evaluated:
    builtins.filter (lib.hasInfix ".programs.git.credentials references a file") (programFailures evaluated);
  evaluates = evaluator: value:
    (builtins.tryEval (builtins.deepSeq (evaluator {ai.programs.git.credentials = value;}).config.ai.programs.git.credentials true)).success;
  installed = backend: evaluated:
    if backend == "hm"
    then evaluated.config.home.packages
    else evaluated.config.packages;
  wrapperRows = config:
    lib.concatMap (backend: let
      evaluated = backends.${backend} config;
    in
      map (runtime: {
        inherit backend runtime;
        bin = exes.${runtime};
        packages = installed backend evaluated;
        env = channel evaluated runtime;
      })
      launcherRuntimes)
    (builtins.attrNames backends);
in {
  checks = {
    module-ai-programs-git-credential-runtime-values = mkTest "ai-programs-git-credential-runtime-values" (
      builtins.all (backend:
        !(evaluates backends.${backend} "literal-token")
        && evaluates backends.${backend} (rv.file {path = tokenFile;})
        && evaluates backends.${backend} (rv.helper {path = "/run/helpers/token";}))
      (builtins.attrNames backends)
    );

    module-ai-programs-git-credential-assertions = mkTest "ai-programs-git-credential-assertions" (
      builtins.all (backend: let
        evaluate = value: backends.${backend} (identityWith value);
        relative = gitFailures (evaluate (rv.file {path = "token";}));
        store = gitFailures (evaluate (rv.file {path = "${builtins.storeDir}/token";}));
      in
        lib.length relative
        == lib.length harnessNames
        && builtins.all (lib.hasInfix "not an absolute path") relative
        && lib.length store == lib.length harnessNames
        && builtins.all (lib.hasInfix "in ${builtins.storeDir}") store
        && gitFailures (evaluate (rv.helper {path = "relative-helper";})) == [])
      (builtins.attrNames backends)
    );

    module-ai-programs-git-configuration-assertions = mkTest "ai-programs-git-configuration-assertions" (
      builtins.all (backend: let
        evaluate = config: backends.${backend} (lib.recursiveUpdate identity config);
        cases = [
          {
            config.ai.programs.gh.configDir = null;
            message = "needs a config directory";
          }
          {
            config.ai.codex.programs.gh.configDir = "relative";
            message = "is not an absolute path";
          }
          {
            config.ai.codex.programs.gh.configDir = "${builtins.storeDir}/gh";
            message = "points into ${builtins.storeDir}";
          }
          {
            config.ai.kiro.programs.git.signing.key = null;
            message = "no signing key";
          }
          {
            config.ai.programs.git.signing.format = null;
            message = "no signing format";
          }
        ];
        storeKey = builtins.tryEval (builtins.deepSeq
          (backends.${backend} {
            ai.programs.git.signing.key = "${builtins.storeDir}/key";
          }).config.ai.programs.git.signing.key
          true);
      in
        builtins.all (case:
          builtins.any (lib.hasInfix case.message) (programFailures (evaluate case.config)))
        cases
        && !storeKey.success
        && (let optedOut = evaluate {ai.kiro.programs.git.enable = false;}; in programFailures optedOut == [] && !((channel optedOut "kiro") ? GIT_CONFIG_GLOBAL)))
      (builtins.attrNames backends)
    );
    module-ai-programs-git-launchers = let
      explicitGit = "/explicit/gitconfig";
      overridden = lib.recursiveUpdate identity {
        ai.codex.environmentVariables.GIT_CONFIG_GLOBAL = explicitGit;
      };
      rows = wrapperRows identity;
    in
      pkgs.runCommand "module-test-ai-programs-git-launchers" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        fail() {
          echo "FAIL: ai-programs-git-launchers: $1" >&2
          exit 1
        }
        ${lib.concatMapStringsSep "\n" (row: ''
            found=
            for package in ${lib.concatMapStringsSep " " toString row.packages}; do
              if [ -e "$package/bin/${row.bin}" ]; then
                found="$package/bin/${row.bin}"
              fi
            done
            [ -n "$found" ] || fail "${row.backend}/${row.runtime}: launcher missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${row.env.GIT_CONFIG_GLOBAL}' "$found" || fail "${row.backend}/${row.runtime}: GIT_CONFIG_GLOBAL"
            ${pkgs.gnugrep}/bin/grep -Fq '${row.env.GH_CONFIG_DIR}' "$found" || fail "${row.backend}/${row.runtime}: GH_CONFIG_DIR"
          '')
          rows}
        ${lib.concatMapStringsSep "\n" (backend: let
            evaluated = backends.${backend} overridden;
            packages = installed backend evaluated;
          in ''
            found=
            for package in ${lib.concatMapStringsSep " " toString packages}; do
              if [ -e "$package/bin/${exes.codex}" ]; then
                found="$package/bin/${exes.codex}"
              fi
            done
            ${pkgs.gnugrep}/bin/grep -Fq '${explicitGit}' "$found" || fail "${backend}/codex: consumer environment did not win"
          '')
          (builtins.attrNames backends)}
        touch "$out"
      '';

    module-ai-programs-git-rendered = let
      token = "TOKEN_MUST_NOT_REACH_HELPER";
      tokenSource = pkgs.writeShellScript "runtime-token-source" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' '${token}'
      '';
      references = {
        file = rv.file {path = tokenFile;};
        helper = rv.helper {path = lib.getExe' tokenSource "runtime-token-source";};
      };
      rows = lib.concatMap (backend:
        lib.mapAttrsToList (kind: reference: {
          inherit backend kind;
          config = (channel (backends.${backend} (identityWith reference)) "codex").GIT_CONFIG_GLOBAL;
          path = reference._runtime.source.${kind};
        })
        references)
      (builtins.attrNames backends);
      unsignedConfigs = map (backend:
        (channel (backends.${backend} (lib.recursiveUpdate identity {ai.programs.git.signing.signByDefault = false;})) "codex").GIT_CONFIG_GLOBAL)
      (builtins.attrNames backends);
    in
      pkgs.runCommand "module-test-ai-programs-git-rendered" {nativeBuildInputs = [pkgs.git];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        fail() {
          echo "FAIL: ai-programs-git-rendered: $1" >&2
          exit 1
        }
        ${lib.concatMapStringsSep "\n" (row: ''
            config=${row.config}
            git config --file "$config" --get-all credential.https://github.com.helper > helpers
            [ "$(wc -l < helpers)" -eq 2 ] || fail "${row.backend}/${row.kind}: helper count"
            [ -z "$(sed -n 1p helpers)" ] || fail "${row.backend}/${row.kind}: reset missing"
            helper="$(sed -n 2p helpers)"
            [ -x "$helper" ] || fail "${row.backend}/${row.kind}: helper is not executable"
            ${pkgs.gnugrep}/bin/grep -Fq '${lib.getExe (rv.reader pkgs)}' "$helper" || fail "${row.backend}/${row.kind}: reader call missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${row.path}' "$helper" || fail "${row.backend}/${row.kind}: reference path missing"
            if ${pkgs.gnugrep}/bin/grep -Fq '${token}' "$helper"; then
              fail "${row.backend}/${row.kind}: token literal reached helper"
            fi
            [ "$(git config --file "$config" user.email)" = bot@example.com ] || fail "${row.backend}/${row.kind}: root settings lost"
            [ "$(git config --file "$config" user.name)" = 'bot (codex)' ] || fail "${row.backend}/${row.kind}: runtime settings lost"
            [ "$(git config --file "$config" commit.gpgSign)" = true ] || fail "${row.backend}/${row.kind}: commit.gpgSign"
            [ "$(git config --file "$config" tag.forceSignAnnotated)" = true ] || fail "${row.backend}/${row.kind}: tag.forceSignAnnotated"
            [ "$(git config --file "$config" tag.gpgSign)" = true ] || fail "${row.backend}/${row.kind}: tag.gpgSign"
          '')
          rows}
        ${lib.concatMapStringsSep "\n" (config: ''
            [ "$(git config --file ${config} commit.gpgSign)" = false ] || fail "unsigned: commit.gpgSign"
            [ "$(git config --file ${config} tag.forceSignAnnotated)" = false ] || fail "unsigned: tag.forceSignAnnotated"
            [ "$(git config --file ${config} tag.gpgSign)" = false ] || fail "unsigned: tag.gpgSign"
          '')
          unsignedConfigs}
        touch "$out"
      '';
  };
}
