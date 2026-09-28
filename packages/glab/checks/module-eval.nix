# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  inherit (import ../../chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
  inherit (import ../lib/schema.nix {inherit lib;}) secretKeys;

  # A stand-in glab: the strict-mode header, then `body`. The logging stubs
  # pass a line that records their argv; the plain ones pass "".
  mkStub = body:
    (pkgs.writeShellScriptBin "glab" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${body}
    '')
    .overrideAttrs (_: {version = "0-test";});
in {
  checks = {
    # ── glab ───────────────────────────────────────────────────────────
    module-glab-default-disabled = mkTest "glab-default-disabled" (
      !(evalHm {}).config.glab.enable && (evalHm {}).config.home.packages == []
    );

    # The settings surface is GENERATED from packages/glab/extracted.json.
    # Assert the shape of what was generated rather than a count: a key that
    # upstream renames must show up as a failure here, and an option tree that
    # collapsed to nothing must not read as "fine".
    module-glab-settings-generated-from-schema = mkTest "glab-settings-generated-from-schema" (
      let
        opts = (evalHm {}).options.glab;
        settingNames =
          builtins.attrNames
          (lib.filterAttrs (n: _: n != "_module") (opts.settings.type.getSubOptions []));
      in
        builtins.elem "git_protocol" settingNames
        && builtins.elem "check_update" settingNames
        && builtins.elem "glamour_style" settingNames
        # `host` is not a credential upstream, so it is an ordinary setting.
        && builtins.elem "host" settingNames
        # token/job_token are secrets and live at the top level as
        # references, so they must NOT also appear as literal settings.
        && !(builtins.elem "token" settingNames)
        && !(builtins.elem "job_token" settingNames)
        # custom_headers is list-typed and has no single-env-var spelling.
        && !(builtins.elem "custom_headers" settingNames)
        && builtins.length settingNames > 20
    );

    # The secret union must accept each reference branch, and the type
    # system (not a runtime throw) is what forbids setting two at once.
    module-glab-secret-branches-accepted = mkTest "glab-secret-branches-accepted" (
      let
        ev = evalHm {
          glab = {
            enable = true;
            settings.host = "gitlab.example.com";
            token.file = "/run/secrets/gitlab-token";
            job_token.helper = "/run/wrappers/bin/job-token";
          };
        };
      in
        ev.config.glab.settings.host
        == "gitlab.example.com"
        && ev.config.glab.token == {file = "/run/secrets/gitlab-token";}
        && ev.config.glab.job_token == {helper = "/run/wrappers/bin/job-token";}
        && builtins.length ev.config.home.packages == 1
    );

    # No secret key accepts a literal: a `plain` value would be interpolated
    # into the world-readable store. Every key the schema marks as a
    # credential must reject it at the TYPE level, and the same key must
    # accept a `file` reference — the positive control that proves the
    # rejection is the type's doing and not some unrelated eval failure.
    # The key list comes from the schema, so a credential key upstream adds
    # later is covered without editing this test.
    module-glab-secrets-reject-literal = mkTest "glab-secrets-reject-literal" (
      let
        evaluates = key: branch:
          (builtins.tryEval (builtins.deepSeq
            (evalHm {glab.${key}.${branch} = "value";}).config.glab.${key}
            true)).success;
      in
        secretKeys
        != []
        && builtins.elem "token" secretKeys
        && builtins.all (key: !(evaluates key "plain") && evaluates key "file") secretKeys
    );

    # extraSettings exports each key upper-cased as a literal, so a key that
    # lands on a secret's env var would put that secret in the store — and
    # override a configured `token.file`. It must fail to evaluate. The
    # rejected keys cover a key name (`job_token`), an env var that is not a
    # key name (`gitlab_token`), an alias, mixed case, and a token the
    # keyring flag misses (`refresh_token`, by key and by env var), the
    # CI auto-login spelling of `job_token` (`ci_job_token`), which only
    # `ciEnvVars` names, and token-named keys the schema does not know
    # (`new_upstream_token`, mixed-case `Foo_Token`); an ordinary new key
    # and `gitlab_ci`, a non-secret CI switch, are the positive controls.
    module-glab-extra-settings-reject-secrets = mkTest "glab-extra-settings-reject-secrets" (
      let
        evaluates = extra:
          (builtins.tryEval (builtins.deepSeq
            (evalHm {
              glab = {
                enable = true;
                settings.host = "gitlab.example.com";
                token.file = "/run/secrets/gitlab-token";
                extraSettings = extra;
              };
            }).config.glab.extraSettings
            true)).success;
      in
        builtins.all (key: !(evaluates {${key} = "LITERAL";}))
        ["gitlab_token" "job_token" "GITLAB_ACCESS_TOKEN" "Oauth_Token" "refresh_token" "REFRESH_TOKEN" "ci_job_token" "CI_JOB_TOKEN" "new_upstream_token" "Foo_Token"]
        && evaluates {brand_new_key = "value";}
        && evaluates {gitlab_ci = "true";}
    );

    # `lib.glab.mkGlab` takes an UNTYPED cfg, so none of the module's type
    # errors reach it. A literal must still fail there rather than being
    # dropped: a stale `token.plain` or `host`, an extraSettings key on a
    # secret's env var (the CI auto-login CI_JOB_TOKEN included) or with a
    # token name the schema does not know, or a secret passed as a
    # `settings` key. `token.file`, an ordinary and a CI
    # extraSettings key, and `settings.host` are the positive controls that
    # prove the failures are these checks' doing.
    module-glab-lib-rejects-literals = mkTest "glab-lib-rejects-literals" (
      let
        stub = mkStub "";
        script = extra:
          (import ../lib/mkGlab.nix {
            inherit lib pkgs;
            cfg =
              {
                package = stub;
                configDir = null;
                settings.host = "gitlab.example.com";
                extraSettings = {};
              }
              // extra;
          }).passthru.wrapperText;
        wraps = extra: (builtins.tryEval (builtins.deepSeq (script extra) true)).success;
      in
        wraps {token.file = "/run/secrets/gitlab-token";}
        && wraps {extraSettings.brand_new_key = "value";}
        && wraps {extraSettings.gitlab_ci = "true";}
        && lib.hasInfix "export GITLAB_HOST" (script {})
        && !(wraps {token.plain = "LITERAL";})
        && !(wraps {token = "LITERAL";})
        && !(wraps {host.plain = "gitlab.example.com";})
        && !(wraps {extraSettings.gitlab_token = "LITERAL";})
        && !(wraps {extraSettings.job_token = "LITERAL";})
        && !(wraps {extraSettings.refresh_token = "LITERAL";})
        && !(wraps {extraSettings.REFRESH_TOKEN = "LITERAL";})
        && !(wraps {extraSettings.ci_job_token = "LITERAL";})
        && !(wraps {extraSettings.CI_JOB_TOKEN = "LITERAL";})
        && !(wraps {extraSettings.new_upstream_token = "LITERAL";})
        && !(wraps {extraSettings.Foo_Token = "LITERAL";})
        && !(wraps {settings.token = "LITERAL";})
        && !(wraps {settings.job_token = "LITERAL";})
        && !(wraps {settings.oauth2_refresh_token = "LITERAL";})
        && !(wraps {settings.refresh_token = "LITERAL";})
    );

    # The whole point of the wrapper: a `file` secret must appear as a
    # RUNTIME read, and its contents must never be interpolated. A file
    # path is only ever `cat`ed; ordinary settings are exported literally.
    module-glab-wrapper-reads-secrets-at-runtime = mkTest "glab-wrapper-reads-secrets-at-runtime" (
      let
        ev = evalHm {
          glab = {
            enable = true;
            settings.host = "gitlab.example.com";
            token.file = "/run/secrets/gitlab-token";
            settings.git_protocol = "ssh";
            extraSettings.brand_new_key = "value";
          };
        };
        wrapped = builtins.head ev.config.home.packages;
        # The script SOURCE — reading its store path back would be IFD
        # inside `nix flake check`.
        script = wrapped.passthru.wrapperText;
      in
        # Secrets: read at invocation, never baked.
        lib.hasInfix ''GITLAB_TOKEN="$('' script
        && lib.hasInfix "/run/secrets/gitlab-token" script
        # The host is a setting, exported as a literal.
        && lib.hasInfix "GITLAB_HOST=gitlab.example.com" script
        # Non-secret setting exports under its real env var. Asserting the
        # assignment and the export, NOT the quoting: nixpkgs'
        # `escapeShellArg` elides quotes for shell-safe values, so
        # "GLAB_GIT_PROTOCOL='ssh'" would be an assertion about lib internals.
        # glab 1.118.0 prefers the GLAB_ name over the legacy alias.
        && lib.hasInfix "GLAB_GIT_PROTOCOL=" script
        && lib.hasInfix "export GLAB_GIT_PROTOCOL" script
        # extraSettings uses glab's uppercase fallback.
        && lib.hasInfix "BRAND_NEW_KEY=" script
        # Absolute store path for cat — the wrapper may run without PATH.
        && !(lib.hasInfix "$(cat " script)
        # Each env var is exported exactly once. A duplicated export is
        # harmless at runtime but means the key partitioning has drifted
        # between the options and the wrapper — which it once had.
        && builtins.length
        (builtins.filter (l: l == "export GITLAB_HOST")
          (lib.splitString "\n" script))
        == 1
    );

    module-glab-keyring-sync-hm-wiring = mkTest "glab-keyring-sync-hm-wiring" (
      let
        ev = evalHm {
          glab = {
            enable = true;
            keyringSync.enable = true;
            settings = {
              git_protocol = "ssh";
              host = "gitlab.example.com";
            };
            token.file = "/run/secrets/gitlab-token";
          };
        };
        pendingFile = "/home/test/.local/state/glab/keyring-sync-pending";
        sync = import ../lib/mkKeyringSync.nix {
          cfg = ev.config.glab;
          configDir = "/home/test/.config/glab-cli";
          inherit lib pkgs;
          inherit pendingFile;
        };
        activation = ev.config.home.activation.glabKeyringSync.text;
        pathUnit = ev.config.systemd.user.paths.glab-keyring-sync;
        service = ev.config.systemd.user.services.glab-keyring-sync;
        wrapper = (builtins.head ev.config.home.packages).passthru.wrapperText;
        scriptAfterProbe = builtins.elemAt (lib.splitString "secret-tool store" sync.scriptText) 1;
      in
        service.Service.Type
        == "oneshot"
        && service.Service.Restart == "no"
        && service.Service.TimeoutStartSec == "5min"
        && pathUnit.Path.PathExists == pendingFile
        && pathUnit.Install.WantedBy == ["graphical-session.target"]
        && lib.hasInfix pendingFile activation
        # Splitting after the only probe invocation proves the runtime secret
        # path occurs later in the generated script, not merely somewhere in it.
        && lib.hasInfix "secret-tool store" sync.scriptText
        && lib.hasInfix "/run/secrets/gitlab-token" scriptAfterProbe
        && lib.hasInfix "glab_sync_host=gitlab.example.com" sync.scriptText
        && lib.hasInfix "--stdin" sync.scriptText
        && lib.hasInfix "--use-keyring" sync.scriptText
        && !(lib.hasInfix "--insecure-storage" sync.scriptText)
        # The synchronized token flows over stdin and is no longer exported by
        # the ordinary wrapper, where it would override keyring storage.
        && !(lib.hasInfix "export glab_sync_token" sync.scriptText)
        && !(lib.hasInfix "export GITLAB_TOKEN" wrapper)
        && lib.hasInfix "export GITLAB_HOST" wrapper
    );

    module-glab-keyring-sync-boundaries = mkTest "glab-keyring-sync-boundaries" (
      let
        failedMessages = ev:
          map (entry: entry.message)
          (builtins.filter (entry: !entry.assertion) ev.config.assertions);
        devenv = evalDevenv {
          glab = {
            enable = true;
            keyringSync.enable = true;
            settings.host = "gitlab.example.com";
            token.file = "/run/secrets/gitlab-token";
          };
        };
        noToken = evalHm {
          glab = {
            enable = true;
            keyringSync.enable = true;
            settings.host = "gitlab.example.com";
          };
        };
        noHost = evalHm {
          glab = {
            enable = true;
            keyringSync.enable = true;
            token.file = "/run/secrets/gitlab-token";
          };
        };
        disabled = evalHm {glab.keyringSync.enable = true;};
      in
        builtins.elem
        "glab.keyringSync.enable is Home Manager-only: devenv may consume a user's existing keyring, but a repository shell must not own login or graphical-session services."
        (failedMessages devenv)
        && builtins.elem
        "glab.keyringSync.enable requires glab.token.file or glab.token.helper."
        (failedMessages noToken)
        && builtins.elem
        "glab.keyringSync.enable requires glab.settings.host so the token cannot be stored for the wrong instance."
        (failedMessages noHost)
        && builtins.elem
        "glab.keyringSync.enable requires glab.enable."
        (failedMessages disabled)
    );

    # HM and devenv must expose the SAME option tree — that is the whole
    # reason the declarations are one shared file.
    module-glab-hm-devenv-option-parity = mkTest "glab-hm-devenv-option-parity" (
      let
        names = ev: builtins.attrNames (lib.filterAttrs (n: _: n != "_module") ev.options.glab);
      in
        names (evalHm {}) == names (evalDevenv {})
    );

    module-glab-devenv-installs-wrapper = mkTest "glab-devenv-installs-wrapper" (
      let
        ev = evalDevenv {
          glab = {
            enable = true;
            settings.host = "gitlab.example.com";
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
          settings.host = "gitlab.example.com";
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
            settings.host = "gitlab.example.com";
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
      stub = mkStub ''
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '';
      cfg = {
        enable = true;
        package = stub;
        configDir = "glab-preflight-cfg";
        settings.host = "https://gitlab.example.com/some/path";
        extraSettings = {};
      };
      wrapped = import ../lib/mkGlab.nix {inherit lib pkgs cfg;};
    in
      pkgs.runCommand "module-test-glab-preflight-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

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
      stub = mkStub ''
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '';
      wrapped = import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = {
          enable = true;
          package = stub;
          # Build-relative, for the reason given on
          # module-glab-preflight-runtime.
          configDir = "glab-ipv6-cfg";
          settings.host = "http://[2001:db8::1]/gitlab";
          extraSettings = {};
        };
      };
    in
      pkgs.runCommand "module-test-glab-ipv6-host-fast-path" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

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
      stub = mkStub ''echo "REACHED-PROGRAM"'';
      wrapped = import ../lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = {
          enable = true;
          package = stub;
          configDir = null;
          settings.host = "gitlab.example.com";
          extraSettings = {};
        };
      };
    in
      pkgs.runCommand "module-test-glab-preflight-no-home" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

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
      stub = mkStub ''
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '';
      mkWrapped = cfgDir: hostValue:
        import ../lib/mkGlab.nix {
          inherit lib pkgs;
          cfg = {
            enable = true;
            package = stub;
            configDir = cfgDir;
            settings.host = hostValue;
            extraSettings = {};
          };
        };
      # Build-relative, for the reason given on
      # module-glab-preflight-runtime.
      httpWrapped = mkWrapped "glab-proto-http" "http://gitlab.internal";
      bareWrapped = mkWrapped "glab-proto-bare" "gitlab.internal";
    in
      pkgs.runCommand "module-test-glab-seeds-http-protocol" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

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
