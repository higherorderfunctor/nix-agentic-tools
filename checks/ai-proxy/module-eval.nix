# cspell:ignore por priorty
# `ai.proxy` core contracts (lib/ai/proxy): selection validation and
# resolution, the per-runtime override, the Home Manager services and
# registry, the devenv rejection of services, the unsupported-runtime
# warnings, and the run-time registry lookup integrations call.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase aiStubs evalDevenv evalDevenvModules evalHmModulesWithSpecialArgs evalHmWithSpecialArgs mkTest;
  proxyLib = aiBase.proxy;
  cliproxyapi = import ../../packages/cliproxyapi/lib/extracted.nix {inherit lib;};

  # The platform is forced in BOTH directions rather than read from the host:
  # this check also runs on aarch64-darwin, where reading the real platform
  # would leave the Linux arms asserting nothing.
  pkgsOn = isLinux:
    pkgs
    // {
      ai = aiStubs;
      stdenv =
        pkgs.stdenv
        // {
          hostPlatform =
            pkgs.stdenv.hostPlatform
            // {
              inherit isLinux;
              system =
                if isLinux
                then "x86_64-linux"
                else "aarch64-darwin";
            };
        };
    };
  evalHmOn = isLinux: evalHmWithSpecialArgs {pkgs = pkgsOn isLinux;};
  evalHm = evalHmOn true;

  failedMessages = result: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) result.config.assertions);
  failsWith = fragments: result:
    builtins.any (message: lib.all (fragment: lib.hasInfix fragment message) fragments) (failedMessages result);

  # Stands in for CLIProxyAPI: records its argv and copies the config it was
  # pointed at, so the start script's rendering can be read back.
  stubProxy = pkgs.writeShellScriptBin "cliproxyapi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf '%s\n' "$@" >"$STUB_OUT/argv"
    ${pkgs.coreutils}/bin/cat "$2" >"$STUB_OUT/config.json"
  '';
  instance = extra:
    {
      clientKey.file = "/run/secrets/ai-proxy-key";
      package = stubProxy;
    }
    // extra;

  # A runtime that consumes the pool, so the per-runtime override and the
  # resolved endpoint are exercised without any real integration.
  record = aiBase.app.mkRuntime {
    inherit pkgs;
    name = "testapp";
    surfaceSupport.proxy = {};
  };
  evalApp = backend: config:
    (
      if backend == "hm"
      then evalHmModulesWithSpecialArgs {pkgs = pkgsOn true;}
      else evalDevenvModules
    ) [
      (aiBase.app.${backend + "Transform"} record)
      {inherit config;}
    ];

  # A renderer standing in for an integration's: one function used on the
  # resolved endpoint at evaluation and on placeholder endpoints at run time.
  render = endpoint: {
    base = endpoint.url;
    helper = endpoint.key.file or endpoint.key.helper or "";
    token = endpoint.key.plain or "";
  };
  argvRender = endpoint: ["-c" "base_url=${endpoint.url}" "-c" "token=${lib.head (builtins.attrValues endpoint.key)}"];
  templates = proxyLib.templatesFile pkgs "check" render;
  argvTemplates = proxyLib.templatesFile pkgs "check-argv" argvRender;
  renderBin = lib.getExe (proxyLib.renderProgram pkgs);
  expected = key:
    builtins.toJSON (render {
      url = "http://127.0.0.1:8317";
      inherit key;
    });
  registry = builtins.toJSON {
    file = {
      key.file = "/run/secrets/ai-proxy-key";
      url = "http://127.0.0.1:8317";
    };
    helper = {
      key.helper = "/run/current-system/sw/bin/proxy-key";
      url = "http://127.0.0.1:8317";
    };
    plain = {
      key.plain = "sk-local";
      url = "http://127.0.0.1:8317";
    };
    quoted = {
      key.plain = "sk\"local";
      url = "http://127.0.0.1:8317";
    };
    withPath = {
      key.plain = "sk-local";
      url = "http://127.0.0.1:8317/v1";
    };
  };
in {
  checks = {
    # Both forms at once, a key without a url and a url without a key each
    # fail with the option path; a valid `url` form and an `instance` form
    # pass. A url carrying a path fails, since every runtime appends its own.
    module-ai-proxy-root-selection-validation = mkTest "ai-proxy-root-selection-validation" (
      failsWith ["ai.proxy:" "not both"] (evalHm {
        ai.proxy = {
          instance = "main";
          url = "http://127.0.0.1:8317";
          key.plain = "sk-local";
        };
      })
      && failsWith ["ai.proxy.url needs `key`"] (evalHm {ai.proxy.url = "http://127.0.0.1:8317";})
      && failsWith ["ai.proxy.key is set without `url`"] (evalHm {ai.proxy.key.plain = "sk-local";})
      && failsWith ["ai.proxy.url must be the proxy origin only"] (evalHm {
        ai.proxy = {
          url = "http://127.0.0.1:8317/v1";
          key.plain = "sk-local";
        };
      })
      && failsWith ["ai.proxy.key.plain must be"] (evalDevenv {
        ai.proxy = {
          url = "http://127.0.0.1:8317";
          key.plain = "sk local";
        };
      })
      && failedMessages (evalHm {
        ai.proxy = {
          url = "http://[::1]:8317";
          key.file = "/run/secrets/ai-proxy-key";
        };
      })
      == []
      && failedMessages (evalDevenv {ai.proxy.instance = "main";}) == []
    );

    # The root selection reaches a consuming runtime as the resolved endpoint;
    # a runtime selection replaces it whole, in either form, on both backends;
    # a runtime's own invalid selection fails with its own option path, even
    # while the runtime is disabled.
    module-ai-proxy-runtime-override = mkTest "ai-proxy-runtime-override" (
      lib.all (backend: let
        resolved = config: (evalApp backend config).config.ai.testapp.normalized.proxy;
        root = {
          url = "http://127.0.0.1:8317";
          key.plain = "sk-local";
        };
      in
        resolved {}
        == null
        && resolved {ai.proxy = root;} == {endpoint = root;}
        && resolved {
          ai = {
            proxy = root;
            testapp.proxy.instance = "work";
          };
        }
        == {instance = "work";}
        && resolved {
          ai = {
            proxy.instance = "main";
            testapp.proxy = root;
          };
        }
        == {endpoint = root;}
        && failsWith ["ai.testapp.proxy:" "not both"] (evalApp backend {
          ai.testapp.proxy = root // {instance = "work";};
        }))
      ["devenv" "hm"]
    );

    # Home Manager resolves an `instance` at evaluation to the entry it
    # declares, the registry's own value; an undeclared name fails while the
    # runtime is enabled. devenv keeps the name for its run-time lookup
    # (module-ai-proxy-runtime-override).
    module-ai-proxy-hm-instance-resolves = mkTest "ai-proxy-hm-instance-resolves" (
      let
        declared = evalApp "hm" {
          ai = {
            proxy = {
              instance = "main";
              instances.main = instance {};
            };
            testapp.enable = true;
          };
        };
      in
        failedMessages declared
        == []
        && declared.config.ai.testapp.normalized.proxy
        == {
          endpoint = {
            key.file = "/run/secrets/ai-proxy-key";
            url = "http://127.0.0.1:8317";
          };
        }
        && failsWith ["ai.testapp is pointed at ai.proxy instance \"work\"" "Home Manager does not declare"] (evalApp "hm" {
          ai = {
            proxy.instance = "work";
            testapp.enable = true;
          };
        })
        && failedMessages (evalApp "hm" {ai.proxy.instance = "work";}) == []
    );

    # One Linux user unit per instance, with its state directory, a start
    # script and a start limit its restarts can reach; a registry mapping
    # each name to its origin and client-key reference; host and port
    # written into the passed-through settings.
    module-ai-proxy-hm-instances = mkTest "ai-proxy-hm-instances" (
      let
        result = evalHm {
          ai.proxy.instances = {
            main = instance {};
            work = instance {
              clientKey.plain = "sk-work";
              host = "::1";
              port = 8318;
            };
          };
        };
        services = result.config.systemd.user.services;
        registryFile = result.config.xdg.configFile.${proxyLib.registryPath};
      in
        failedMessages result
        == []
        && builtins.attrNames services == ["ai-proxy-main" "ai-proxy-work"]
        && services.ai-proxy-main.Service.StateDirectory == "ai-proxy/main"
        && services.ai-proxy-main.Install.WantedBy == ["default.target"]
        # Restarts every 5s stop after 3 starts in 60s, so a start that
        # always fails leaves the unit failed instead of looping.
        && services.ai-proxy-main.Service.Restart == "on-failure"
        && services.ai-proxy-main.Service.RestartSec * services.ai-proxy-main.Unit.StartLimitBurst < services.ai-proxy-main.Unit.StartLimitIntervalSec
        && builtins.fromJSON registryFile.text
        == {
          main = {
            key.file = "/run/secrets/ai-proxy-key";
            url = "http://127.0.0.1:8317";
          };
          work = {
            key.plain = "sk-work";
            url = "http://[::1]:8318";
          };
        }
        && (cliproxyapi.render result.config.ai.proxy.instances.work.settings).value
        == {
          server = {
            host = "::1";
            port = 8318;
          };
        }
    );

    # Instance settings are typed from the extraction: a value of the wrong
    # type, or outside an extracted enum, or a bare string where a secret
    # belongs, fails evaluation; a secret anywhere, a map value included,
    # renders to its literal or to its path for the start script; a key the
    # extraction does not know passes through; unset options and empty typed
    # objects are left out of the rendered config.
    module-ai-proxy-typed-settings = mkTest "ai-proxy-typed-settings" (
      let
        settingsOf = settings: (evalHm {ai.proxy.instances.main = instance {inherit settings;};}).config.ai.proxy.instances.main.settings;
        rejects = settings: !(builtins.tryEval (builtins.deepSeq (settingsOf settings) true)).success;
        rendered = settings: (cliproxyapi.render (settingsOf settings)).value;
        accountOf = account: (evalHm {ai.proxy.instances.main = instance {accounts.a = account;};}).config.ai.proxy.instances.main.accounts.a;
        rejectsAccount = account: !(builtins.tryEval (builtins.deepSeq (accountOf account) true)).success;
      in
        # An account is typed where the extraction types it and open to any
        # other key: the untyped key reaches the plan's fields as given, a
        # file secret leaves them for the start script. The open keys refuse
        # the login's identity and tokens, an `ignored` field (`email`,
        # `id_token`) or a credential-shaped name.
        rejectsAccount {priority = "high";}
        && rejectsAccount {access_token = "sk-ant-oat01-x";}
        && rejectsAccount {api_key = "sk-x";}
        && rejectsAccount {email = "you@example.com";}
        && rejectsAccount {id_token = "tok";}
        && rejectsAccount {refresh_token = "sk-ant-ort01-x";}
        && cliproxyapi.renderAccount (accountOf {
          priority = 1;
          proxy_url.file = "/run/secrets/account-proxy";
          request_retry = 2;
        })
        == {
          secrets = [
            {
              path = ["proxy_url"];
              secret.file = "/run/secrets/account-proxy";
            }
          ];
          value = {
            priority = 1;
            request_retry = 2;
          };
        }
        && rejects {routing.strategy = "most-recent";}
        && rejects {server.tls.enable = "yes";}
        && rejects {api-keys.claude = [{keys = [{weight = "heavy";}];}];}
        # A proxy URL and an upstream header can carry a credential, so they
        # take the secret type: a bare string fails, and a header is a
        # secret at its map node.
        && rejects {requests.proxy-url = "socks5://user:pass@127.0.0.1:1080";}
        && rejects {api-keys.claude = [{headers.Authorization = "Bearer sk";}];}
        && cliproxyapi.render (settingsOf {
          api-keys.claude = [
            {
              headers = {
                Authorization.file = "/run/secrets/claude-auth";
                X-Team.plain = "infra";
              };
              keys = [{proxy-url.helper = "/run/secrets/key-proxy";}];
            }
          ];
          requests.proxy-url.plain = "http://127.0.0.1:3128";
        })
        == {
          secrets = [
            {
              path = ["api-keys" "claude" 0 "headers" "Authorization"];
              secret.file = "/run/secrets/claude-auth";
            }
            {
              path = ["api-keys" "claude" 0 "keys" 0 "proxy-url"];
              secret.helper = "/run/secrets/key-proxy";
            }
          ];
          value = {
            api-keys.claude = [
              {
                headers.X-Team = "infra";
                keys = [{}];
              }
            ];
            requests.proxy-url = "http://127.0.0.1:3128";
            server = {
              host = "127.0.0.1";
              port = 8317;
            };
          };
        }
        && rendered {
          future.section = 1;
          routing = {
            retry = {};
            strategy = "fill-first";
          };
        }
        == {
          future.section = 1;
          routing.strategy = "fill-first";
          server = {
            host = "127.0.0.1";
            port = 8317;
          };
        }
    );

    module-ai-proxy-refused-account-fields = mkTest "ai-proxy-refused-account-fields" (
      lib.all (eval:
        lib.all (name: let
          account =
            (eval {
              ai.proxy.instances.main = instance {
                allowUnrecognizedAccountFields = ["*.${name}"];
                accounts.a.${name} = "refused-value";
              };
            }).config.ai.proxy.instances.main.accounts.a;
        in
          !(builtins.tryEval (builtins.deepSeq account true)).success)
        ["access_token" "api_key" "email" "id_token" "plan_type" "refresh_token" "type"])
      [evalHm evalDevenv]
    );

    module-ai-proxy-unrecognized-accounts-warn = mkTest "ai-proxy-unrecognized-accounts-warn" (
      lib.all (eval: let
        result = eval {
          ai.proxy.instances.main = instance {
            accounts."user.with.dots" = {
              headers.X-Team.file = "/run/secrets/header";
              priorty = 3;
              request_retry = 2;
            };
          };
        };
        warnings = result.config.warnings;
        fields = (cliproxyapi.renderAccount result.config.ai.proxy.instances.main.accounts."user.with.dots").value;
      in
        builtins.length warnings
        == 2
        && lib.hasInfix ''ai.proxy.instances.main.accounts."user.with.dots".priorty: unrecognized key'' (builtins.head warnings)
        && lib.hasInfix ''did you mean `ai.proxy.instances.main.accounts."user.with.dots".priority`?'' (builtins.head warnings)
        && lib.hasInfix ''[ "*.priorty" ]'' (builtins.head warnings)
        && fields
        == {
          priorty = 3;
          request_retry = 2;
        })
      [evalHm evalDevenv]
    );

    module-ai-proxy-unrecognized-settings-warn = mkTest "ai-proxy-unrecognized-settings-warn" (
      lib.all (eval: let
        result = eval {
          ai.proxy.instances.main = instance {
            settings = {
              api-keys.claude = [
                {
                  headers.X-Team.plain = "infra";
                  keys = [
                    {
                      api-key.file = "/run/secrets/upstream";
                      weight = 1;
                    }
                  ];
                }
              ];
              server.por = 9000;
            };
          };
        };
        warnings = result.config.warnings;
      in
        builtins.length warnings
        == 1
        && lib.hasInfix "ai.proxy.instances.main.settings.server.por: unrecognized key" (builtins.head warnings)
        && lib.hasInfix "did you mean `ai.proxy.instances.main.settings.server.port`?" (builtins.head warnings)
        && (cliproxyapi.render result.config.ai.proxy.instances.main.settings).value.server.por == 9000)
      [evalHm evalDevenv]
    );

    module-ai-proxy-warning-allowlists = mkTest "ai-proxy-warning-allowlists" (
      lib.all (eval: let
        evaluated = extra:
          eval {
            ai.proxy.instances.main = instance ({
                accounts.a.request_retry = 2;
                allowUnrecognizedAccountFields = ["*.request_retry"];
                allowUnrecognizedSettings = ["server.por"];
                settings.server.por = 9000;
              }
              // extra);
          };
        result = evaluated {};
        stale = evaluated {allowUnrecognizedSettings = ["server.port"];};
      in
        result.config.warnings
        == []
        && (cliproxyapi.render result.config.ai.proxy.instances.main.settings).value.server.por == 9000
        && result.config.ai.proxy.instances.main.accounts.a.request_retry == 2
        && builtins.any (lib.hasInfix "stale allowlist entry `server.port` is already declared") stale.config.warnings)
      [evalHm evalDevenv]
    );

    # Instances are checked one by one: a name that cannot be a unit, a
    # wildcard host, a missing or example client key, a secret in settings
    # whose file or helper path the start script cannot quote, an auth dir
    # that is not absolute, `~` or `~/…` (each accepted form passes), an
    # account name that cannot be an auth file, and a shared port.
    module-ai-proxy-hm-instance-validation = mkTest "ai-proxy-hm-instance-validation" (
      failsWith ["ai.proxy.instances.\"bad name\"" "systemd unit"] (evalHm {ai.proxy.instances."bad name" = instance {};})
      && failsWith ["ai.proxy.instances.main.host" "binds every interface"] (evalHm {ai.proxy.instances.main = instance {host = "0.0.0.0";};})
      && failsWith ["ai.proxy.instances.main.clientKey must be set"] (evalHm {ai.proxy.instances.main = instance {clientKey = null;};})
      && failsWith ["example keys"] (evalHm {ai.proxy.instances.main = instance {clientKey.plain = "your-api-key-1";};})
      && failsWith ["ai.proxy.instances.main.clientKey.file must be"] (evalHm {ai.proxy.instances.main = instance {clientKey.file = "relative/key";};})
      && failsWith ["ai.proxy.instances.main.settings.api-keys.claude.\"0\".keys.\"0\".api-key.file must be"] (evalHm {
        ai.proxy.instances.main = instance {settings.api-keys.claude = [{keys = [{api-key.file = "relative/key";}];}];};
      })
      && lib.all (authDir:
        failsWith ["ai.proxy.instances.main.settings.oauth.auth-dir = \"${authDir}\" must be an absolute path"] (evalHm {
          ai.proxy.instances.main = instance {settings.oauth.auth-dir = authDir;};
        })) ["" "relative/auth" "~other/auth"]
      && lib.all (authDir: failedMessages (evalHm {ai.proxy.instances.main = instance {settings.oauth.auth-dir = authDir;};}) == []) ["/var/lib/cpa" "~" "~/cpa"]
      && failsWith ["ai.proxy.instances.main.accounts.\"claude.json/x\": an account is named after its auth file"] (evalHm {
        ai.proxy.instances.main = instance {accounts."claude.json/x".priority = 1;};
      })
      && failsWith ["share a port" "8317 (a, b)"] (evalHm {
        ai.proxy.instances = {
          a = instance {};
          b = instance {};
        };
      })
    );

    # Darwin has no service writer yet: no units, a warning naming the
    # instances, and the registry still written for a proxy run by hand.
    module-ai-proxy-hm-darwin-warns = mkTest "ai-proxy-hm-darwin-warns" (
      let
        result = evalHmOn false {ai.proxy.instances.main = instance {};};
      in
        result.config.systemd.user.services
        == {}
        && result.config.xdg.configFile ? ${proxyLib.registryPath}
        && builtins.any (lib.hasInfix "ai.proxy.instances (main) defines CLIProxyAPI services") result.config.warnings
    );

    # devenv runs no user services, so instances fail evaluation there.
    module-ai-proxy-devenv-rejects-instances = mkTest "ai-proxy-devenv-rejects-instances" (
      failsWith ["ai.proxy.instances (main) is Home Manager only"] (evalDevenv {ai.proxy.instances.main = instance {};})
    );

    # Only a selection is a request: `instances` alone defines services, so
    # it stays quiet where ai-warnings-delivery's generated cases make a
    # selection warn.
    module-ai-proxy-instances-are-not-a-request = mkTest "ai-proxy-instances-are-not-a-request" (
      let
        result = evalHm {
          ai = {
            kimchi.enable = true;
            kiro.cli.enable = true;
            proxy.instances.main = instance {};
          };
        };
      in
        !(builtins.any (lib.hasPrefix "ai.proxy is set") result.config.warnings)
    );

    # The start script renders the config into the unit's state directory:
    # host and port from the options, the client key read from its file and
    # appended to any keys in settings, each secret in settings written in its
    # place from its literal, file or helper (an upstream header and a proxy
    # URL among them) while the store holds only a file or helper's path, the
    # auth dir defaulted there, and only the config
    # path in the proxy's argv. A missing secret file or a failing helper
    # stops the start before the proxy runs. A `~` auth dir resolves against
    # HOME, as CLIProxyAPI resolves it, and its accounts are written there.
    module-ai-proxy-start-script-renders-config = let
      result = evalHm {
        ai.proxy.instances.main = instance {
          settings = {
            access.api-keys = [{plain = "sk-extra";} {file = "/run/secrets/extra-key";}];
            api-keys = {
              claude = [
                {
                  headers.Authorization.file = "/run/secrets/upstream-header";
                  keys = [{api-key.file = "/run/secrets/upstream-claude";}];
                }
              ];
              codex = [{keys = [{api-key.helper = "/run/secrets/upstream-codex";}];}];
            };
            management.secret-key.plain = "panel-key";
            requests.proxy-url.file = "/run/secrets/upstream-proxy";
          };
        };
        ai.proxy.instances.tilde = instance {
          accounts.claude-tilde.priority = 5;
          port = 8318;
          settings.oauth.auth-dir = "~/cpa-auth";
        };
      };
      execOf = name: result.config.systemd.user.services."ai-proxy-${name}".Service.ExecStart;
    in
      pkgs.runCommand "module-test-ai-proxy-start-script-renders-config" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq=${lib.getExe pkgs.jq}
        mkdir -p state state-tilde out secrets home/cpa-auth
        printf '%s' '{"refresh_token": "sk-ant-ort01-xyz", "type": "claude"}' >home/cpa-auth/claude-tilde.json
        helper() {
          printf '#!${pkgs.runtimeShell}\n%s\n' "$1" >secrets/upstream-codex
          chmod +x secrets/upstream-codex
        }
        start() {
          rm -f out/*
          STATE_DIRECTORY="$PWD/state" STUB_OUT="$PWD/out" ./start
        }
        printf 'sk-from-file\n' >secrets/ai-proxy-key
        printf 'sk-extra-file\n' >secrets/extra-key
        printf 'sk-ant-upstream\n' >secrets/upstream-claude
        printf 'Bearer sk-header\n' >secrets/upstream-header
        printf 'socks5://user:pass@127.0.0.1:1080\n' >secrets/upstream-proxy
        helper 'echo sk-codex-upstream'
        sed "s|/run/secrets/|$PWD/secrets/|g" ${execOf "main"} >start
        chmod +x start
        start
        [ "$(cat out/argv)" = "$(printf -- '--config\n%s' "$PWD/state/config.yaml")" ]
        [ "$(stat -c %a state/config.yaml)" = 600 ]
        "$jq" -e --arg auth "$PWD/state/auth" '
          .server == {host: "127.0.0.1", port: 8317}
          and .access["api-keys"] == ["sk-extra", "sk-extra-file", "sk-from-file"]
          and .["api-keys"].claude[0].keys[0]["api-key"] == "sk-ant-upstream"
          and .["api-keys"].codex[0].keys[0]["api-key"] == "sk-codex-upstream"
          and .["api-keys"].claude[0].headers.Authorization == "Bearer sk-header"
          and .requests["proxy-url"] == "socks5://user:pass@127.0.0.1:1080"
          and .management["secret-key"] == "panel-key"
          and .oauth["auth-dir"] == $auth
        ' out/config.json >/dev/null
        settings="$(grep -o '/nix/store/[a-z0-9]*-ai-proxy-main-settings.json' start)"
        "$jq" -e '.["api-keys"].claude[0].keys[0] == {} and .access["api-keys"] == ["sk-extra", null]' "$settings" >/dev/null
        if grep -q 'sk-ant-upstream\|sk-codex-upstream\|sk-extra-file\|sk-header\|user:pass' "$settings" start; then
          echo "an upstream secret reached the store" >&2
          exit 1
        fi
        # Only the file-sourced proxy URL's path is in the store.
        grep -qF "$PWD/secrets/upstream-proxy" start
        sed "s|/run/secrets/|$PWD/secrets/|g" ${execOf "tilde"} >start-tilde
        chmod +x start-tilde
        HOME="$PWD/home" STATE_DIRECTORY="$PWD/state-tilde" STUB_OUT="$PWD/out" ./start-tilde
        "$jq" -e --arg auth "$PWD/home/cpa-auth" '.oauth["auth-dir"] == $auth' out/config.json >/dev/null
        "$jq" -e '.priority == 5 and .refresh_token == "sk-ant-ort01-xyz"' home/cpa-auth/claude-tilde.json >/dev/null
        rm secrets/upstream-claude
        if start 2>err; then
          echo "expected a missing secret file to fail the start" >&2
          exit 1
        fi
        grep -qF "$PWD/secrets/upstream-claude — the file is missing" err
        [ ! -e out/argv ]
        printf 'sk-ant-upstream\n' >secrets/upstream-claude
        helper 'exit 3'
        if start 2>err; then
          echo "expected a failing helper to fail the start" >&2
          exit 1
        fi
        [ ! -e out/argv ]
        echo PASS >$out
      '';

    # Account fields are reconciled into existing auth files, one ledger per
    # account. The first start writes the declared fields, an empty prefix,
    # a key the extraction does not type and a proxy URL read from its file
    # included, beside a field set in the panel and the login's tokens, keeps
    # the file's mode and skips an account with no file. An account declaring
    # only file secrets gets them too, a header set in place in the file's
    # headers. The second start, with one field and two accounts no longer
    # declared, removes exactly what the first wrote and drops the ledger of
    # an account whose file is gone.
    module-ai-proxy-start-script-reconciles-accounts = let
      startWith = accounts: (evalHm {ai.proxy.instances.main = instance {inherit accounts;};}).config.systemd.user.services.ai-proxy-main.Service.ExecStart;
      claude = "claude-1a2b3c4d-you@example.com";
      first = startWith {
        ${claude} = {
          headers.X-Team.plain = "infra";
          prefix = "";
          priority = 10;
          proxy_url.file = "/run/secrets/account-proxy";
          # Not extracted: the open account type passes it through.
          request_retry = 2;
        };
        codex-absent.weight = 2;
        codex-gone.weight = 2;
        codex-secrets = {
          headers.X-Auth.file = "/run/secrets/account-header";
          proxy_url.file = "/run/secrets/codex-proxy";
        };
      };
      second = startWith {
        ${claude} = {
          headers.X-Team.plain = "infra";
          prefix = "";
        };
      };
      login = builtins.toJSON {
        access_token = "sk-ant-oat01-a<b>&c";
        email = "you@example.com";
        headers.X-Panel = "kept";
        note = "from the panel";
        prefix = "panel";
        refresh_token = "sk-ant-ort01-xyz";
        type = "claude";
      };
    in
      pkgs.runCommand "module-test-ai-proxy-start-script-reconciles-accounts" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq=${lib.getExe pkgs.jq}
        mkdir -p state/auth out secrets
        printf 'sk-from-file\n' >secrets/ai-proxy-key
        printf 'socks5://user:pass@127.0.0.1:1080\n' >secrets/account-proxy
        account=state/auth/${claude}.json
        printf '%s' ${lib.escapeShellArg login} >"$account"
        chmod 640 "$account"
        printf '%s' '{"refresh_token": "codex-refresh", "type": "codex"}' >state/auth/codex-gone.json
        printf 'Bearer opaque-header-value\n' >secrets/account-header
        printf 'http://cdx:pw2@10.0.0.1:3128\n' >secrets/codex-proxy
        printf '%s' '{"headers": {"X-Panel": "kept"}, "refresh_token": "codex-secrets-refresh", "type": "codex"}' >state/auth/codex-secrets.json
        run() {
          sed "s|/run/secrets/|$PWD/secrets/|g" "$1" >start
          chmod +x start
          STATE_DIRECTORY="$PWD/state" STUB_OUT="$PWD/out" ./start
        }
        tokens() {
          "$jq" -r '.access_token, .refresh_token' "$account"
        }
        before="$(tokens)"
        run ${first}
        # The accounts' secrets are read from their files at start: the store
        # plan and the script hold only the files' paths.
        plan="$(grep -o '/nix/store/[a-z0-9]*-nat-own-plan.json' start)"
        if grep -q -e 'user:pass' -e 'opaque-header-value' -e 'cdx:pw2' "$plan" start; then
          echo "an account secret reached the store" >&2
          exit 1
        fi
        grep -qF "$PWD/secrets/account-proxy" start
        "$jq" -e '
          .priority == 10 and .prefix == ""
          and .proxy_url == "socks5://user:pass@127.0.0.1:1080"
          and .request_retry == 2
          and .headers == {"X-Panel": "kept", "X-Team": "infra"}
          and .note == "from the panel" and .email == "you@example.com"
        ' "$account" >/dev/null
        [ "$(tokens)" = "$before" ]
        [ "$(stat -c %a "$account")" = 640 ]
        "$jq" -e '.weight == 2 and .refresh_token == "codex-refresh"' state/auth/codex-gone.json >/dev/null
        "$jq" -e '
          .headers == {"X-Auth": "Bearer opaque-header-value", "X-Panel": "kept"}
          and .proxy_url == "http://cdx:pw2@10.0.0.1:3128"
          and .refresh_token == "codex-secrets-refresh"
        ' state/auth/codex-secrets.json >/dev/null
        [ "$(ls state/auth)" = "$(printf '%s\n' ${claude}.json codex-gone.json codex-secrets.json)" ]
        mkdir -p state/own/accounts
        printf '{"managed_paths": [["note"]], "version": 1}\n' >state/own/accounts/claude-deleted.json
        run ${second}
        "$jq" -e '
          (has("priority") | not) and (has("proxy_url") | not)
          and (has("request_retry") | not) and .prefix == ""
          and .headers == {"X-Panel": "kept", "X-Team": "infra"}
          and .note == "from the panel"
        ' "$account" >/dev/null
        [ "$(tokens)" = "$before" ]
        "$jq" -e '(has("weight") | not) and .refresh_token == "codex-refresh"' state/auth/codex-gone.json >/dev/null
        "$jq" -e '
          .headers == {"X-Panel": "kept"} and (has("proxy_url") | not)
          and .refresh_token == "codex-secrets-refresh"
        ' state/auth/codex-secrets.json >/dev/null
        [ ! -e state/own/accounts/codex-gone.json ]
        [ ! -e state/own/accounts/claude-deleted.json ]
        [ -e state/own/accounts/${claude}.json ]
        echo PASS >$out
      '';

    # The run-time lookup: each key form renders through its template, argv
    # renders one line per element, and every bad input fails loudly naming the
    # registry or the instance.
    module-ai-proxy-render-program = pkgs.runCommand "module-test-ai-proxy-render-program" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/config"
      fails() {
        local pattern="$1"
        shift
        if "$@" 2>err; then
          echo "expected failure: $*" >&2
          exit 1
        fi
        grep -qF -- "$pattern" err || {
          cat err >&2
          exit 1
        }
      }
      fails "is missing or unreadable" ${renderBin} plain ${templates}
      mkdir -p config/ai-proxy
      printf '%s' ${lib.escapeShellArg registry} >config/${proxyLib.registryPath}
      [ "$(${renderBin} plain ${templates})" = ${lib.escapeShellArg (expected {plain = "sk-local";})} ]
      [ "$(${renderBin} file ${templates})" = ${lib.escapeShellArg (expected {file = "/run/secrets/ai-proxy-key";})} ]
      [ "$(${renderBin} helper ${templates})" = ${lib.escapeShellArg (expected {helper = "/run/current-system/sw/bin/proxy-key";})} ]
      [ "$(${renderBin} --lines plain ${argvTemplates})" = "$(printf -- '-c\nbase_url=http://127.0.0.1:8317\n-c\ntoken=sk-local')" ]
      fails 'has no instance "missing"; it lists: file, helper, plain, quoted, withPath.' ${renderBin} missing ${templates}
      fails 'instance "quoted"' ${renderBin} quoted ${templates}
      fails 'url must be the proxy origin only' ${renderBin} withPath ${templates}
      fails 'array of single-line strings' ${renderBin} --lines plain ${templates}
      fails 'usage: ai-proxy-render' ${renderBin} plain
      printf '{' >config/${proxyLib.registryPath}
      fails 'is not valid JSON' ${renderBin} plain ${templates}
      echo PASS >$out
    '';
  };
}
