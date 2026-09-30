{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  inherit (import ../../chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
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
    token = rv.file {path = "token";};
    settings.check_update = rv.file {path = "setting";};
  };
  wrapper = import ../lib/mkGlab.nix {
    inherit lib pkgs;
    cfg = configured;
  };
  wrapperFor = config:
    (import ../lib/mkGlab.nix {
      inherit lib pkgs;
      cfg = configured // config;
    }).wrapperText;
  secretFile = (cfg {token = rv.file {path = "/run/secret";};}).token;
in {
  checks = {
    module-glab-map-priorities = mkTest "glab-map-priorities" (let
      cases = [
        {
          definitions = [{host = lib.mkDefault "default";} {host = "explicit";}];
          expected.host = "explicit";
        }
        {
          definitions = [{host = "default";} {host = lib.mkForce "forced";}];
          expected.host = "forced";
        }
        {
          definitions = [{host = lib.mkIf false "omitted";}];
          expected = {};
        }
        {
          definitions = [{gitlab_token = lib.mkDefault "discarded";} {gitlab_token = rv.file {path = "/run/token";};}];
          expected = null;
        }
      ];
      verify = entry: let
        extraSettings = lib.mkMerge entry.definitions;
        merged = (cfg {inherit extraSettings;}).extraSettings;
      in
        succeeds merged
        && (entry.expected == null || merged == entry.expected)
        && succeeds (wrapperFor {inherit extraSettings;});
      rejected = {gitlab_token = lib.mkForce "literal";};
    in
      lib.all verify cases
      && !succeeds (cfg {extraSettings = rejected;}).extraSettings
      && !succeeds (wrapperFor {extraSettings = rejected;}));

    module-glab-default-disabled = mkTest "glab-default-disabled" (!(evalHm {}).config.glab.enable);
    module-glab-reference-types = mkTest "glab-reference-types" (
      succeeds (cfg configured)
      && succeeds (cfg (configured // {host = "gitlab.example.com";}))
      && !succeeds (cfg (configured // {token = "literal";}))
      && !succeeds (cfg (configured // {extraSettings.gitlab_token = "literal";}))
      && succeeds (cfg (configured // {extraSettings.gitlab_token = rv.file {path = "/run/token";};}))
    );
    module-glab-lib-map-classification = mkTest "glab-lib-map-classification" (let
      extraSettings.gitlab_token = rv.file {path = "/run/token";};
      stamped = (cfg {inherit extraSettings;}).extraSettings.gitlab_token;
    in
      stamped._runtime.secret
      && succeeds (wrapperFor {inherit extraSettings;})
      && !succeeds (wrapperFor {extraSettings.GITLAB_HOST = stamped;})
      && !succeeds (wrapperFor {extraSettings.gitlab_token = "literal";}));
    module-glab-lib-validation =
      mkTest "glab-lib-validation" (!succeeds
      (import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = configured // {token = "literal";};
      }).wrapperText);
    module-glab-alias-argv-guard = mkTest "glab-alias-argv-guard" (
      !succeeds (wrapperFor {host = secretFile;})
      && !succeeds (wrapperFor {configDir = secretFile;})
      && !succeeds (wrapperFor {extraSettings.host = secretFile;})
      && !succeeds (wrapperFor {extraSettings.GITLAB_HOST = secretFile;})
      && !succeeds (wrapperFor {extraSettings.gitlab_host = secretFile;})
      && !succeeds (wrapperFor {extraSettings.GLAB_CONFIG_DIR = secretFile;})
      && !succeeds (wrapperFor {extraSettings.glab_config_dir = secretFile;})
      && succeeds (wrapperFor {extraSettings.GITLAB_HOST = rv.file {path = "/run/public-host";};})
      && succeeds (wrapperFor {extraSettings.GLAB_CONFIG_DIR = rv.file {path = "/run/public-dir";};})
    );
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
    module-glab-keyring-token-aliases = mkTest "glab-keyring-token-aliases" (let
      aliases = [
        "CI_JOB_TOKEN"
        "GITLAB_ACCESS_TOKEN"
        "GITLAB_TOKEN"
        "JOB_TOKEN"
        "OAUTH_TOKEN"
        "REFRESH_TOKEN"
        "ToKeN"
        "gitlab_access_token"
        "gitlab_token"
        "oauth2_refresh_token"
        "token"
      ];
      token = rv.file {path = "/run/secret/glab-alias";};
      keyring = {keyringSync.enable = true;};
      rejected = name: let
        extraSettings = {${name} = token;};
        config = configured // keyring // {inherit extraSettings;};
      in
        !succeeds (wrapperFor (keyring // {inherit extraSettings;}))
        && !succeeds (builtins.head (evalHm {glab = config // {enable = true;};}).config.home.packages).wrapperText;
      script = wrapperFor keyring;
    in
      lib.all rejected aliases
      && !succeeds (wrapperFor (keyring // {job_token = token;}))
      && !succeeds (wrapperFor (keyring // {settings.token = token;}))
      && !succeeds (wrapperFor (keyring // {settings.GITLAB_TOKEN = token;}))
      && !(lib.hasInfix "export GITLAB_TOKEN" script)
      && !(lib.hasInfix "export JOB_TOKEN" script));
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
        printf token-value > expected-token
        cmp expected-token login-token
        test ! -e pending
        grep -F -- '--stdin' login-argv
        if grep -F 'token-value' login-argv; then exit 1; fi
        rm expected-token login-token token
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
      printf token > expected-token
      cmp expected-host host-delivered
      cmp expected-token token-delivered
      test "$(cat setting-delivered)" = false
      rm token-delivered
      : > host
      if ${pkgs.bash}/bin/bash ${pkgs.writeText "glab-wrapper" wrapper.wrapperText} status >out 2>diagnostic; then exit 1; fi
      test ! -e token-delivered
      grep -F 'glab.host: reference resolved empty' diagnostic
      touch "$out"
    '';
    module-glab-devenv-installs-wrapper = mkTest "glab-devenv-installs-wrapper" (
      let
        ev = evalDevenv {
          glab = {
            enable = true;
            host = "gitlab.example.com";
          };
        };
      in
        builtins.length ev.config.packages == 1
    );

    # The ONE intentional HM/devenv difference: devenv defaults configDir to
    # the project state dir, so a project-local glab does not mutate the
    # user's global ~/.config/glab-cli. It is a `config` default and NOT a
    # different option declaration, which is why the option-tree parity test
    # still holds — assert both halves so a later edit cannot quietly turn
    # this into a declaration difference.
    module-glab-configdir-facet-defaults = mkTest "glab-configdir-facet-defaults" (
      let
        base = {
          enable = true;
          host = "gitlab.example.com";
        };
        hm = evalHm {glab = base;};
        dv = evalDevenv {glab = base;};
        overridden = evalDevenv {glab = base // {configDir = "/tmp/explicit";};};
      in
        hm.config.glab.configDir
        == null
        && dv.config.glab.configDir == "/tmp/devenv-state/glab-cli"
        # mkDefault, so a project can still point it elsewhere.
        && overridden.config.glab.configDir == "/tmp/explicit"
    );

    module-glab-codex-sandbox-grants-effective-configdir = mkTest "glab-codex-sandbox-grants-effective-configdir" (
      let
        base = {
          ai.codex = {
            enable = true;
            native.settings.sandbox_mode = "workspace-write";
          };
          glab = {
            enable = true;
            host = "gitlab.example.com";
          };
        };
        hmEval = evalHm base;
        devenv =
          (evalDevenv (lib.recursiveUpdate base {
            glab.configDir = "/home/test/.config/glab-cli";
          })).config;
      in
        builtins.elem
        "/home/test/.config/glab-cli"
        (hmCodexSettings hmEval).sandbox_workspace_write.writable_roots
        && builtins.elem
        "/home/test/.config/glab-cli"
        devenv.files.".codex/config.toml".source.value.sandbox_workspace_write.writable_roots
    );

    # Runtime test of the preflight, with a STUB standing in for glab so the
    # check needs no Go build. Covers what the wrapper does to the
    # filesystem before exec: create the config dir 0700, seed the hosts:
    # entry using the BARE hostname (scheme and path stripped), repair a
    # too-permissive config.yml to 0600, and then NOT re-seed.
    #
    # Behavior, not emitted text: a grep proving the line exists says
    # nothing about whether the shell actually does it.
    #
    # configDir is RELATIVE on purpose, so it lands in the build directory.
    # An absolute `/tmp/…` is not hermetic: Nix's per-build private /tmp is
    # a SANDBOX feature, and the sandbox is off by default on Darwin — one
    # of this repo's two CI platforms — so the test would touch (and
    # `rm -rf`) a shared host path. It also makes the `-d` assertions
    # stronger, since a leftover directory from an earlier run cannot
    # satisfy them.
    module-glab-preflight-runtime = let
      stub =
        (pkgs.writeShellScriptBin "glab" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
        '')
      .overrideAttrs (_: {version = "0-test";});
      cfg = {
        enable = true;
        package = stub;
        configDir = "glab-preflight-cfg";
        host = "https://gitlab.example.com/some/path";
        token = rv.file {path = toString (pkgs.writeText "fixture-token" "test-credential");};
        job_token = null;
        settings = {};
        extraSettings = {};
      };
      wrapped = import ../lib/mkGlab.nix {inherit lib pkgs cfg;};
    in
      pkgs.runCommand "module-test-glab-preflight-runtime" {} ''
        export HOME="$PWD/home"
        # Matches cfg.configDir above; the wrapper resolves it against the
        # build directory, which is this script's cwd.
        cfg=glab-preflight-cfg
        rm -rf "$cfg"
        export GLAB_STUB_LOG="$PWD/seed.log"
        : > "$GLAB_STUB_LOG"

        [ ! -d "$cfg" ] || {
          echo "FAIL: precondition — config dir already exists" >&2
          exit 1
        }

        ${wrapped}/bin/glab version >/dev/null

        mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$cfg")
        [ "$mode" = "700" ] || {
          echo "FAIL: config dir mode $mode, expected 700" >&2
          exit 1
        }

        grep -qxF -- 'config set --host gitlab.example.com api_protocol https' "$GLAB_STUB_LOG" || {
          echo "FAIL: seeding not invoked with the bare host + https. log:" >&2
          cat "$GLAB_STUB_LOG" >&2
          exit 1
        }

        printf 'hosts:\n  gitlab.example.com:\n' > "$cfg/config.yml"
        chmod 664 "$cfg/config.yml"
        ${wrapped}/bin/glab version >/dev/null
        mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$cfg/config.yml")
        [ "$mode" = "600" ] || {
          echo "FAIL: config.yml mode $mode after repair, expected 600" >&2
          exit 1
        }

        : > "$GLAB_STUB_LOG"
        ${wrapped}/bin/glab version >/dev/null
        if grep -q 'config set' "$GLAB_STUB_LOG"; then
          echo "FAIL: re-seeded although the hosts: entry was already present" >&2
          exit 1
        fi

        # The fast path must not FALSE-POSITIVE on a host differing only
        # where the dots are. This is the regression test for the pattern
        # matching the preflight must NOT go back to: as an ERE,
        # `gitlab.example.com` also matches `gitlab-example-com:`, so
        # seeding would be skipped while the real entry is absent — this
        # preflight's own bug, one layer down. The current implementation
        # compares fixed strings and has no such failure mode; this guards
        # against a future edit reintroducing pattern matching. A false
        # NEGATIVE is harmless here; a false positive is not.
        : > "$GLAB_STUB_LOG"
        printf 'hosts:\n  gitlab-example-com:\n' > "$cfg/config.yml"
        chmod 600 "$cfg/config.yml"
        ${wrapped}/bin/glab version >/dev/null
        grep -qF -- 'config set --host gitlab.example.com ' "$GLAB_STUB_LOG" || {
          echo "FAIL: a near-miss host suppressed seeding — the fast path is matching patterns, not fixed strings" >&2
          exit 1
        }

        echo PASS > "$out"
      '';

    # A bracketed IPv6 host must round-trip. The fast path used to be an
    # ERE with only `.` escaped, on the claim that hostnames are
    # [A-Za-z0-9.-]; `[` and `]` in an IPv6 literal either change the match
    # or make grep error, so the entry was never found and the wrapper
    # reseeded on every invocation. Now a fixed-string compare, which has no
    # escaping question at all.
    module-glab-ipv6-host-fast-path = let
      stub =
        (pkgs.writeShellScriptBin "glab" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
        '')
      .overrideAttrs (_: {version = "0-test";});
      wrapped = import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = {
          enable = true;
          package = stub;
          # Build-relative, for the reason given on
          # module-glab-preflight-runtime.
          configDir = "glab-ipv6-cfg";
          host = "http://[2001:db8::1]/gitlab";
          token = rv.file {path = toString (pkgs.writeText "fixture-token" "test-credential");};
          job_token = null;
          settings = {};
          extraSettings = {};
        };
      };
    in
      pkgs.runCommand "module-test-glab-ipv6-host-fast-path" {} ''
        export HOME="$PWD/home"
        export GLAB_STUB_LOG="$PWD/seed.log"
        # Bound once; must match cfg.configDir above.
        cfg=glab-ipv6-cfg
        rm -rf "$cfg"
        : > "$GLAB_STUB_LOG"

        # First run seeds, with the bracket host intact and http from scheme.
        ${wrapped}/bin/glab version >/dev/null
        grep -qF -- 'config set --host [2001:db8::1] api_protocol http' "$GLAB_STUB_LOG" || {
          echo "FAIL: IPv6 host not seeded correctly. log:" >&2
          cat "$GLAB_STUB_LOG" >&2
          exit 1
        }
        [ -d "$cfg" ] || {
          echo "FAIL: configDir $cfg was not created" >&2
          exit 1
        }

        # With the entry present, the fast path must MATCH and not reseed.
        # A pattern match could not: `[`/`]` are regex metacharacters.
        printf 'hosts:\n    [2001:db8::1]:\n' > "$cfg/config.yml"
        chmod 600 "$cfg/config.yml"
        : > "$GLAB_STUB_LOG"
        ${wrapped}/bin/glab version >/dev/null
        if grep -q 'config set' "$GLAB_STUB_LOG"; then
          echo "FAIL: reseeded despite the IPv6 entry being present" >&2
          cat "$GLAB_STUB_LOG" >&2
          exit 1
        fi

        echo PASS > "$out"
      '';

    # With configDir unset AND no HOME/XDG_CONFIG_HOME, the wrapper must
    # report what to set rather than dying on bash's bare
    # `HOME: unbound variable` from `set -u`. Reachable in practice: a tool
    # that REPLACES the environment (Claude Code's MCP `env` field) can
    # spawn this with no HOME at all.
    module-glab-preflight-no-home = let
      stub =
        (pkgs.writeShellScriptBin "glab" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          echo "REACHED-PROGRAM"
        '')
      .overrideAttrs (_: {version = "0-test";});
      wrapped = import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = {
          enable = true;
          package = stub;
          configDir = null;
          host = "gitlab.example.com";
          token = rv.file {path = toString (pkgs.writeText "fixture-token" "test-credential");};
          job_token = null;
          settings = {};
          extraSettings = {};
        };
      };
    in
      pkgs.runCommand "module-test-glab-preflight-no-home" {} ''
        if got=$(env -u HOME -u XDG_CONFIG_HOME -u GLAB_CONFIG_DIR \
                   ${wrapped}/bin/glab version 2>&1); then
          echo "FAIL: expected a non-zero exit with no HOME (got: $got)" >&2
          exit 1
        fi
        case "$got" in
          *"unbound variable"*)
            echo "FAIL: died on bash's unbound-variable error, not the guard: $got" >&2
            exit 1 ;;
          *"cannot locate a config directory"*) : ;;
          *)
            echo "FAIL: aborted, but not via the guard (got: $got)" >&2
            exit 1 ;;
        esac

        # The stub prints REACHED-PROGRAM, so assert it did not. The
        # non-zero check above already rules out "warned, then exec'd
        # successfully" — the stub exits 0, so that path would have made the
        # `if` fire. This closes the remaining gap: a guard that warns and
        # then reaches a program which itself fails. Without it the stub's
        # marker is a control nothing reads.
        case "$got" in
          *REACHED-PROGRAM*)
            echo "FAIL: guard fired but the program was still reached: $got" >&2
            exit 1 ;;
        esac

        echo PASS > "$out"
      '';

    # `api_protocol` must follow the scheme on the configured host rather
    # than being hardcoded https, or an http:// instance gets a config entry
    # contradicting how it is actually reached. Separate test because it
    # needs a differently-configured wrapper.
    module-glab-seeds-http-protocol = let
      stub =
        (pkgs.writeShellScriptBin "glab" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
        '')
      .overrideAttrs (_: {version = "0-test";});
      mkWrapped = cfgDir: hostValue:
        import ../lib/mkGlab.nix {
          inherit lib pkgs;
          cfg = {
            enable = true;
            package = stub;
            configDir = cfgDir;
            host = hostValue;
            token = rv.file {path = toString (pkgs.writeText "fixture-token" "test-credential");};
            job_token = null;
            settings = {};
            extraSettings = {};
          };
        };
      # Build-relative, for the reason given on
      # module-glab-preflight-runtime.
      httpWrapped = mkWrapped "glab-proto-http" "http://gitlab.internal";
      bareWrapped = mkWrapped "glab-proto-bare" "gitlab.internal";
    in
      pkgs.runCommand "module-test-glab-seeds-http-protocol" {} ''
        export HOME="$PWD/home"
        export GLAB_STUB_LOG="$PWD/seed.log"

        # Must match the configDirs passed to mkWrapped above.
        httpCfg=glab-proto-http
        bareCfg=glab-proto-bare

        rm -rf "$httpCfg" "$bareCfg"
        : > "$GLAB_STUB_LOG"
        ${httpWrapped}/bin/glab version >/dev/null
        grep -qxF -- 'config set --host gitlab.internal api_protocol http' "$GLAB_STUB_LOG" || {
          echo "FAIL: http:// host was not seeded with api_protocol http. log:" >&2
          cat "$GLAB_STUB_LOG" >&2
          exit 1
        }
        # The configured dir must be the one actually created. Without this
        # a wrong configDir (e.g. a literal "$cfg" left by a bad refactor)
        # still satisfies the grep above, so the test would pass while
        # exercising the wrong path — which is exactly what deadnix caught.
        [ -d "$httpCfg" ] || {
          echo "FAIL: configDir $httpCfg was not created" >&2
          exit 1
        }

        # No scheme falls back to https, matching glab's own default.
        : > "$GLAB_STUB_LOG"
        ${bareWrapped}/bin/glab version >/dev/null
        grep -qxF -- 'config set --host gitlab.internal api_protocol https' "$GLAB_STUB_LOG" || {
          echo "FAIL: scheme-less host did not fall back to https. log:" >&2
          cat "$GLAB_STUB_LOG" >&2
          exit 1
        }
        [ -d "$bareCfg" ] || {
          echo "FAIL: configDir $bareCfg was not created" >&2
          exit 1
        }

        echo PASS > "$out"
      '';
  };
}
