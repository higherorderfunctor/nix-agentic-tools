{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  rv = import ../../../lib/runtime-values {inherit lib;};
  succeeds = value: (builtins.tryEval (builtins.toJSON value)).success;
  declarations = import ../modules/options.nix {inherit lib;};
  cfg = config: (lib.evalModules {modules = [declarations {config.glab = config;}];}).config.glab;
  fake = pkgs.writeShellScriptBin "glab" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    if [[ "$1" == config ]]; then exit 0; fi
    printf '%s' "$GITLAB_HOST" > host-delivered
    printf '%s' "$GITLAB_TOKEN" > token-delivered
    printf '%s' "$GLAB_CHECK_UPDATE" > setting-delivered
  '';
  package = fake // {version = "test";};
  configured = {
    inherit package;
    host = rv.file {path = "host";};
    token = rv.file {
      path = "token";
      newline = "preserve";
    };
    settings.check_update = rv.file {path = "setting";};
  };
  wrapper = import ../lib/mkGlab.nix {
    inherit lib pkgs;
    cfg = configured;
  };
in {
  checks = {
    module-glab-default-disabled = mkTest "glab-default-disabled" (!(evalHm {}).config.glab.enable);
    module-glab-reference-types = mkTest "glab-reference-types" (
      succeeds (cfg configured)
      && succeeds (cfg (configured // {host = "gitlab.example.com";}))
      && !succeeds (cfg (configured // {token = "literal";}))
      && !succeeds (cfg (configured // {extraSettings.gitlab_token = "literal";}))
      && succeeds (cfg (configured // {extraSettings.gitlab_token = rv.file {path = "/run/token";};}))
    );
    module-glab-lib-validation =
      mkTest "glab-lib-validation" (!succeeds
      (import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = configured // {token = "literal";};
      }).wrapperText);
    module-glab-settings-generated-from-schema = mkTest "glab-settings-generated-from-schema" (let
      options = (evalHm {}).options.glab;
      fields = options.settings.type.getSubOptions [];
    in
      fields ? check_update && fields ? git_protocol && !(fields ? token) && !(fields ? host) && options ? token && options ? host);
    module-glab-hm-devenv-option-parity = mkTest "glab-hm-devenv-option-parity" (builtins.attrNames (evalHm {}).options.glab == builtins.attrNames (evalDevenv {}).options.glab);
    module-glab-keyring-sync = mkTest "glab-keyring-sync" (let
      evaluated = evalHm {
        glab =
          configured
          // {
            enable = true;
            keyringSync.enable = true;
          };
      };
      sync = import ../lib/mkKeyringSync.nix {
        cfg = evaluated.config.glab;
        configDir = "/tmp/glab";
        pendingFile = "/tmp/pending";
        inherit lib pkgs;
      };
      script = (builtins.head evaluated.config.home.packages).wrapperText;
    in
      evaluated.config.systemd.user.services ? glab-keyring-sync
      && lib.hasInfix "runtime-value-read" sync.scriptText
      && lib.hasInfix "--stdin" sync.scriptText
      && !(lib.hasInfix "export GITLAB_TOKEN" script)
      && lib.hasInfix "export GITLAB_HOST" script);
    module-glab-keyring-runtime = let
      auth = pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        [[ -z "''${GITLAB_TOKEN:-}" ]]
        printf '%s\n' "$@" > login-argv
        ${pkgs.coreutils}/bin/cat > login-token
      '';
      secretTool = pkgs.writeShellScriptBin "secret-tool" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        if [[ "$1" == store ]]; then
          [[ "''${LOCKED:-0}" != 1 ]] || exit 1
          ${pkgs.coreutils}/bin/cat >/dev/null
        fi
      '';
      sync = import ../lib/mkKeyringSync.nix {
        inherit lib;
        pkgs = pkgs // {libsecret = secretTool;};
        cfg = configured // {package = auth;};
        configDir = "config";
        pendingFile = "pending";
      };
    in
      pkgs.runCommand "module-glab-keyring-runtime" {} ''
        printf 'gitlab.example.com\n' > host
        printf 'token-value\n\n' > token
        touch pending
        export GITLAB_TOKEN=ignored
        ${sync.script}
        cmp token login-token
        test ! -e pending
        grep -F -- '--stdin' login-argv
        if grep -F 'token-value' login-argv; then exit 1; fi
        rm login-token token
        touch pending
        export LOCKED=1
        if ${sync.script} >out 2>diagnostic; then exit 1; fi
        test ! -e pending
        test ! -e login-token
        if grep -F 'reference' diagnostic; then exit 1; fi
        touch "$out"
      '';
    module-glab-runtime = pkgs.runCommand "module-glab-runtime" {} ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      printf 'gitlab.example.com\n' > host
      printf 'token\n\n' > token
      printf 'false\n' > setting
      ${pkgs.bash}/bin/bash ${pkgs.writeText "glab-wrapper" wrapper.wrapperText} status
      printf 'gitlab.example.com' > expected-host
      cmp expected-host host-delivered
      cmp token token-delivered
      test "$(cat setting-delivered)" = false
      rm token-delivered
      : > host
      if ${pkgs.bash}/bin/bash ${pkgs.writeText "glab-wrapper" wrapper.wrapperText} status >out 2>diagnostic; then exit 1; fi
      test ! -e token-delivered
      grep -F 'glab.host: reference resolved empty' diagnostic
      touch "$out"
    '';
  };
}
