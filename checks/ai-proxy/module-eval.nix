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
    supportedPools = ["proxy"];
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

    # One Linux user unit per instance, with its state directory and a start
    # script; a registry mapping each name to its origin and client-key
    # reference; host and port written into the passed-through settings.
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
        && result.config.ai.proxy.instances.work.settings.server
        == {
          host = "::1";
          port = 8318;
        }
    );

    # Instances are checked one by one: a name that cannot be a unit, a
    # wildcard host, a missing or example client key, and a shared port.
    module-ai-proxy-hm-instance-validation = mkTest "ai-proxy-hm-instance-validation" (
      failsWith ["ai.proxy.instances.\"bad name\"" "systemd unit"] (evalHm {ai.proxy.instances."bad name" = instance {};})
      && failsWith ["ai.proxy.instances.main.host" "binds every interface"] (evalHm {ai.proxy.instances.main = instance {host = "0.0.0.0";};})
      && failsWith ["ai.proxy.instances.main.clientKey must be set"] (evalHm {ai.proxy.instances.main = instance {clientKey = null;};})
      && failsWith ["example keys"] (evalHm {ai.proxy.instances.main = instance {clientKey.plain = "your-api-key-1";};})
      && failsWith ["ai.proxy.instances.main.clientKey.file must be"] (evalHm {ai.proxy.instances.main = instance {clientKey.file = "relative/key";};})
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

    # A selection reaching Kimchi or Kiro warns on both backends with the
    # standard unsupported-surface message; services alone are not a request.
    module-ai-proxy-unsupported-runtimes-warn = mkTest "ai-proxy-unsupported-runtimes-warn" (
      let
        runtimes = {
          kimchi.enable = true;
          kiro.cli.enable = true;
        };
        warned = backend: runtime: result:
          builtins.any (lib.hasPrefix "ai.proxy is set but ${backend} does not deliver it to ${runtime} (reason: ") result.config.warnings;
        selected = {
          hm = evalHm {ai = runtimes // {proxy.instance = "main";};};
          devenv = evalDevenv {ai = runtimes // {proxy.instance = "main";};};
        };
        servicesOnly = evalHm {ai = runtimes // {proxy.instances.main = instance {};};};
      in
        lib.all (backend: warned backend "kimchi" selected.${backend} && warned backend "kiro" selected.${backend}) ["devenv" "hm"]
        && !(builtins.any (lib.hasPrefix "ai.proxy is set") servicesOnly.config.warnings)
    );

    # The start script renders the config into the unit's state directory:
    # host and port from the options, the client key read from its file and
    # appended to any keys in settings, the auth dir defaulted there, and only
    # the config path in the proxy's argv.
    module-ai-proxy-start-script-renders-config = let
      result = evalHm {
        ai.proxy.instances.main = instance {
          settings.access.api-keys = ["sk-extra"];
        };
      };
      exec = result.config.systemd.user.services.ai-proxy-main.Service.ExecStart;
    in
      pkgs.runCommand "module-test-ai-proxy-start-script-renders-config" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq=${lib.getExe pkgs.jq}
        mkdir -p state out secrets
        printf 'sk-from-file\n' >secrets/key
        sed "s|/run/secrets/ai-proxy-key|$PWD/secrets/key|" ${exec} >start
        chmod +x start
        STATE_DIRECTORY="$PWD/state" STUB_OUT="$PWD/out" ./start
        [ "$(cat out/argv)" = "$(printf -- '--config\n%s' "$PWD/state/config.yaml")" ]
        [ "$(stat -c %a state/config.yaml)" = 600 ]
        "$jq" -e --arg auth "$PWD/state/auth" '
          .server == {host: "127.0.0.1", port: 8317}
          and .access["api-keys"] == ["sk-extra", "sk-from-file"]
          and .oauth["auth-dir"] == $auth
        ' out/config.json >/dev/null
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
