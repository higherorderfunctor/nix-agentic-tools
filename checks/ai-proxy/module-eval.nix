{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows claudeSettings evalDevenv evalHm mkTest rejectsChange;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  http = "http://plain.invalid:8080";
  https = "http://secure.invalid:8443";
  instanceHttp = "http://instance.invalid:8080";
  local = "http://runtime.invalid:8000";
  onMain = fields: fields // {instance = "main";};
  protocols = http: https: {inherit http https;};
  # Fixed answers: do not derive the expected sibling or instance from the input.
  # The root null rows check every runtime's wiring on both backends; selected
  # cases exercise the shared resolution path with one runtime per backend.
  cases = {
    "an explicit root HTTP null blocks sibling fallback" = {
      root = protocols null https;
      expected = protocols null https;
    };
    "an explicit root HTTPS null blocks sibling fallback" = {
      root = protocols http null;
      expected = protocols http null;
    };
    "an explicit runtime HTTP null leaves the already inherited HTTPS fallback" = {
      root = {inherit http;};
      runtime.http = null;
      expected = protocols null http;
      runtimes = ["claude"];
    };
    "an explicit runtime HTTPS null leaves the already inherited HTTP fallback" = {
      root = {inherit https;};
      runtime.https = null;
      expected = protocols https null;
      runtimes = ["kiro"];
    };
    "an explicit runtime HTTPS null overrides the inherited instance default" = {
      root = onMain {inherit http;};
      runtime.https = null;
      expected = protocols http null;
      expectedInstance = "main";
    };
    "root HTTP from mkDefault still supplies a sibling fallback" = {
      root.http = lib.mkDefault http;
      expected = protocols http http;
      runtimes = ["codex"];
    };
    "root HTTP null blocks only the HTTP instance origin" = {
      root = onMain {http = null;};
      expected = protocols null https;
      expectedInstance = "main";
      runtimes = ["kimchi"];
    };
    "root HTTP wins over a root instance while HTTPS uses the instance" = {
      root = onMain {inherit http;};
      expected = protocols http https;
      expectedInstance = "main";
      # Airlock checks Claude's root HTTP override on both backends.
      runtimes = ["codex" "kimchi" "kiro"];
    };
    "root HTTP wins over the runtime instance without filling HTTPS" = {
      root = {inherit http;};
      runtime.instance = "main";
      expected = protocols http https;
      expectedInstance = "main";
      runtimes = ["kiro"];
    };
    "root HTTPS null blocks only the HTTPS instance origin" = {
      root = onMain {
        inherit http;
        https = null;
      };
      expected = protocols http null;
      expectedInstance = "main";
    };
    "root HTTPS supplies HTTP in the absence of an instance" = {
      root = {inherit https;};
      expected = protocols https https;
      runtimes = ["claude"];
    };
    "root HTTPS wins over a root instance while HTTP uses the instance" = {
      root = onMain {https = local;};
      expected = protocols instanceHttp local;
      expectedInstance = "main";
    };
    "runtime HTTP null blocks its own instance's HTTP origin" = {
      runtime = onMain {http = null;};
      expected = protocols null https;
      expectedInstance = "main";
    };
    "runtime HTTP overrides only root HTTP" = {
      root = protocols http https;
      runtime.http = local;
      expected = protocols local https;
    };
    "runtime HTTP supplies HTTPS without a root definition or instance" = {
      runtime = {inherit http;};
      expected = protocols http http;
    };
    "runtime HTTP wins over its own instance without filling HTTPS" = {
      runtime = onMain {inherit http;};
      expected = protocols http https;
      expectedInstance = "main";
    };
    "runtime HTTPS overrides only root HTTPS" = {
      root = protocols http https;
      runtime.https = local;
      expected = protocols http local;
    };
    "runtime HTTPS supplies HTTP without a root definition or instance" = {
      runtime = {inherit https;};
      expected = protocols https https;
    };
    "runtime instance null clears both instance origins" = {
      root.instance = "main";
      runtime.instance = null;
      expected = protocols null null;
      runtimes = ["codex"];
    };
    "runtime instance null does not clear explicit root protocols" = {
      root = onMain (protocols null https);
      runtime.instance = null;
      expected = protocols null https;
    };
    "runtime instance reselection replaces the old instance origin but not the explicit root origin" = {
      root = onMain {inherit http;};
      runtime.instance = "other";
      expected = protocols http local;
      expectedInstance = "other";
      runtimes = ["kiro"];
    };
  };
  semantics = lib.mapAttrs' (backend: evaluate: let
    name = "ai-proxy-${backend}-resolution";
    observe = test:
      (evaluate {
        ai =
          {
            internal.proxyInstances = {
              main = {
                http = instanceHttp;
                inherit https;
              };
              other = protocols local local;
            };
            proxy = test.root or {};
          }
          // lib.genAttrs runtimes (_: {proxy = test.runtime or {};});
      }).config.ai;
    rows = lib.mapAttrsToList (scenario: test: let
      actual = observe test;
    in
      map (runtime:
        lib.nameValuePair "${runtime}: ${scenario}; resolved protocols, instance and normalization match" (
          actual.${runtime}.proxy
          == test.expected // {instance = test.expectedInstance or null;}
          && actual.${runtime}.normalized.proxy == test.expected
        ))
      (test.runtimes or runtimes))
    cases;
    # Force just the defining field: otherwise an unrelated module error could
    # satisfy the rejection. Each control travels through the same merge.
    rejectsEmpty = path: valid:
      rejectsChange (value: lib.getAttrFromPath path (evaluate (lib.setAttrByPath path value)).config) {
        inherit valid;
        invalid = "";
        expected = valid;
      };
  in
    lib.nameValuePair "module-${name}" (mkTest name (checkRows name (
      builtins.listToAttrs (lib.concatLists rows)
      // lib.optionalAttrs (backend == "hm") {
        "ai.kiro.proxy.https rejects an empty string" = rejectsEmpty ["ai" "kiro" "proxy" "https"] https;
        "ai.proxy.http rejects an empty string" = rejectsEmpty ["ai" "proxy" "http"] http;
      }
    ))))
  backends;
  executable = {
    codex = "codex";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  # The actual installed launcher executes this sentinel. No inference or
  # credentials are needed, and an absent default is observably different.
  sentinel = pkgs.runCommand "proxy-environment-sentinel" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    cat > "$out/bin/proxy-sentinel" <<'EOF'
    #!${pkgs.bash}/bin/bash
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # Launchers add their own arguments, so the mode is an environment variable.
    if [[ "''${PROXY_SENTINEL_MODE-}" == no-proxy ]]; then
      printf '%s\n' "''${NO_PROXY-absent}"
      exit
    fi
    printf '%s\n' "''${HTTP_PROXY-absent}" "''${HTTPS_PROXY-absent}" "''${https_proxy-absent}"
    EOF
    chmod +x "$out/bin/proxy-sentinel"
    for name in ${lib.escapeShellArgs (builtins.attrValues executable)}; do
      ln -s proxy-sentinel "$out/bin/$name"
    done
  '';
  launcherConfig = runtime: environmentVariables: proxy: let
    native = {
      inherit environmentVariables;
      package = sentinel;
    };
  in
    lib.recursiveUpdate (harness.setEnable runtime true) {
      ai = {
        inherit proxy;
        ${runtime} =
          if runtime == "kiro"
          then {cli = native;}
          else native;
      };
    };
  launchers = lib.concatMapAttrs (backend: evaluate:
    lib.mapAttrs' (runtime: exe: let
      name = "module-ai-proxy-${backend}-${runtime}-launcher";
      installedConfig = config: let
        result = evaluate config;
      in
        builtins.head (
          if backend == "hm"
          then result.config.home.packages
          else result.config.packages
        );
      installed = env: proxy: installedConfig (launcherConfig runtime env proxy);
      selectedInstance = installedConfig (lib.recursiveUpdate (launcherConfig runtime {} {instance = "main";}) {
        ai.internal.proxyInstances.main = {inherit http https;};
      });
      kimchiNative = installedConfig (lib.recursiveUpdate (launcherConfig runtime {} {inherit http https;}) {
        ai.kimchi.native.harnessSettings.httpProxy = local;
      });
      native = installed {
        HTTP_PROXY = local;
        HTTPS_PROXY = "";
      } {inherit http https;};
      nativeLowercase = installed {https_proxy = local;} {inherit http https;};
      ordinary = installed {} {inherit http https;};
      sameProtocol = installed {} {inherit http;};
    in
      lib.nameValuePair name (pkgs.runCommand name {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home" DEVENV_ROOT="$PWD"
        mkdir -p "$HOME"
        unset http_proxy https_proxy
        check_output() {
          local row=$1 expected=$2 actual
          shift 2
          if ! actual=$("$@"); then
            printf '%s: launcher failed\n' "$row" >&2
            return 1
          fi
          if [[ "$actual" != "$expected" ]]; then
            printf '%s: expected %q, got %q\n' "$row" "$expected" "$actual" >&2
            return 1
          fi
        }
        check_proxy() {
          local row=$1 expected
          expected=$(printf '%s\n' "$2" "$3" "$4")
          shift 4
          check_output "$row" "$expected" "$@"
        }
        # Kiro installs the same wrapper on both backends; HM checks its loopback default.
        ${lib.optionalString (backend == "hm" || runtime != "kiro") ''
          check_output 'instance supplies loopback NO_PROXY' '127.0.0.1,localhost,::1' \
            env -u NO_PROXY -u no_proxy PROXY_SENTINEL_MODE=no-proxy ${selectedInstance}/bin/${exe}
        ''}
        check_proxy 'both unset protocols use their configured defaults' ${lib.escapeShellArg http} ${lib.escapeShellArg https} absent \
          env -u HTTP_PROXY -u HTTPS_PROXY ${ordinary}/bin/${exe}
        ${lib.optionalString (backend == "hm" || runtime == "kiro") ''
          check_proxy 'ambient lowercase HTTP suppresses only the uppercase HTTP default' absent ${lib.escapeShellArg https} absent \
            env -u HTTP_PROXY -u HTTPS_PROXY http_proxy=ambient ${ordinary}/bin/${exe}
        ''}
        check_proxy 'single configured HTTP origin reaches both protocol variables' ${lib.escapeShellArg http} ${lib.escapeShellArg http} absent \
          env -u HTTP_PROXY -u HTTPS_PROXY ${sameProtocol}/bin/${exe}
        check_proxy 'ambient uppercase values win even when empty' ambient "" absent \
          env HTTP_PROXY=ambient HTTPS_PROXY= ${ordinary}/bin/${exe}
        check_proxy 'configured uppercase values win over ambient and defaults' ${lib.escapeShellArg local} "" absent \
          env HTTP_PROXY=ambient HTTPS_PROXY=ambient ${native}/bin/${exe}
        check_proxy 'configured lowercase HTTPS suppresses only the uppercase HTTPS default' ${lib.escapeShellArg http} absent ${lib.escapeShellArg local} \
          env -u HTTP_PROXY -u HTTPS_PROXY ${nativeLowercase}/bin/${exe}
        ${lib.optionalString (runtime == "kimchi" && backend == "hm") ''
          check_proxy 'Kimchi native httpProxy suppresses both defaults' absent absent absent \
            env -u HTTP_PROXY -u HTTPS_PROXY ${kimchiNative}/bin/${exe}
        ''}
        echo PASS > "$out"
      ''))
    executable)
  backends;
  packageWarnings = lib.concatMapAttrs (backend: evaluate:
    lib.listToAttrs (map (runtime: let
      name = "ai-proxy-${backend}-${runtime}-null-package-warning";
      warning = "ai.proxy is set but ai.${runtime}.package is null; the proxy is delivered only through the managed launcher.";
      proxyWarnings = extra: package: proxy:
        lib.filter (lib.hasPrefix "ai.proxy ")
        (evaluate {
          ai = {
            inherit proxy;
            ${runtime} =
              {
                enable = true;
                inherit package;
              }
              // extra;
          };
        }).config.warnings;
      warnings = proxyWarnings {};
      rows =
        {
          "explicit null protocols are silent without a package" =
            warnings null (protocols null null) == [];
          "managed launcher delivers the proxy without warning" = warnings sentinel {inherit http;} == [];
          "unmanaged launcher warns about undelivered proxy" = warnings null {inherit http;} == [warning];
        }
        // lib.optionalAttrs (backend == "hm" && runtime == "kimchi") {
          # Kimchi's native httpProxy (HM only) suppresses the launcher defaults.
          "native Kimchi proxy suppresses the managed-launcher warning" =
            proxyWarnings {native.harnessSettings.httpProxy = local;} null {inherit http;} == [];
        };
    in
      lib.nameValuePair "module-${name}" (mkTest name (checkRows name rows))) ["codex" "kimchi"]))
  backends;
  settings = lib.mapAttrs' (backend: evaluate: let
    name = "ai-proxy-${backend}-settings-and-warnings";
    claude = proxy: native:
      (claudeSettings (evaluate {
        ai = {
          inherit proxy;
          claude = {
            enable = true;
            native.settings.env = native;
          };
        };
      })).env;
    blocked = claude {
      http = null;
      inherit https;
    } {};
    overridden = claude {inherit http https;} {
      HTTP_PROXY = local;
      HTTPS_PROXY = local;
    };
    shared = claude {inherit http https;} {};
  in
    lib.nameValuePair "module-${name}" (mkTest name (checkRows name {
      "Claude delivers both configured origins in settings" = shared.HTTP_PROXY == http && shared.HTTPS_PROXY == https;
      "Claude explicit null HTTP omits only HTTP_PROXY" = !(blocked ? HTTP_PROXY) && blocked.HTTPS_PROXY == https;
      "Claude native env wins for both protocols" = overridden.HTTP_PROXY == local && overridden.HTTPS_PROXY == local;
    })))
  backends;
  usageTracking = lib.mapAttrs' (backend: evaluate: let
    name = "ai-proxy-${backend}-kiro-usage-tracking";
    failures = root: proxy:
      map (entry: entry.message) (lib.filter (entry: !entry.assertion)
        (evaluate {
          ai = {
            proxy = root;
            internal.proxyInstances.main = {inherit http https;};
            kiro = {
              inherit proxy;
              cli = {
                enable = true;
                usageTracking.enable = true;
              };
            };
          };
        }).config.assertions);
    optOut = protocols null null;
  in
    lib.nameValuePair "module-${name}" (mkTest name (checkRows name {
      "explicit null protocols permit tracking with a root instance" = failures {instance = "main";} optOut == [];
      "explicit null protocols permit tracking with a root protocol" = failures {inherit http;} optOut == [];
      "inherited HTTP proxy reports the tracking conflict and opt-out remedy" =
        failures {inherit http;} {}
        == ["ai.kiro.cli.usageTracking owns HTTP(S)/ALL/NO_PROXY (both cases) and NODE_EXTRA_CA_CERTS; remove conflicting ai.environmentVariables / ai.kiro.cli.environmentVariables entries, or opt out of ai.proxy with ai.kiro.proxy = {http = null; https = null;}."];
    })))
  backends;
in {
  checks =
    semantics
    // launchers
    // packageWarnings
    // settings
    // usageTracking
    // {
      module-ai-proxy-kimchi-native-priority = let
        name = "ai-proxy-kimchi-native-priority";
        delivered = native: let
          result = evalHm {
            ai = {
              proxy = {inherit http;};
              kimchi = {
                enable = true;
                native.harnessSettings = native;
              };
            };
          };
          path = "${result.config.ai.kimchi.configDir}/harness/settings.json";
        in
          result.config.ai.files.${path}.content.value;
      in
        mkTest name (checkRows name {
          "native proxy reaches settings instead of the shared origin" = (delivered {httpProxy = local;}).httpProxy == local;
          "shared proxy is not written to native settings" = !(delivered {} ? httpProxy);
        });
    };
}
