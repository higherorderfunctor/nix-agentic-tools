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
  cases = {
    both = {
      root = {inherit http https;};
      expected = {inherit http https;};
    };
    default-priority = {
      root.http = lib.mkDefault http;
      expected = {
        inherit http;
        https = http;
      };
    };
    empty = {
      root = {};
      expected = {
        http = null;
        https = null;
      };
    };
    http = {
      root = {inherit http;};
      expected = {
        inherit http;
        https = http;
      };
    };
    https = {
      root = {inherit https;};
      expected = {
        http = https;
        inherit https;
      };
    };
    instance-http = {
      root = {
        inherit http;
        instance = "main";
      };
      expected = {inherit http https;};
      expectedInstance = "main";
    };
    instance-null-https = {
      root = {
        inherit http;
        instance = "main";
        https = null;
      };
      expected = {
        inherit http;
        https = null;
      };
      expectedInstance = "main";
    };
    instance-null-peer = {
      root = {
        instance = "main";
        http = null;
      };
      expected = {
        http = null;
        inherit https;
      };
      expectedInstance = "main";
    };
    instance-peer-fallback = {
      root = {
        https = local;
        instance = "main";
      };
      expected = {
        http = instanceHttp;
        https = local;
      };
      expectedInstance = "main";
    };
    null-http = {
      root = {
        http = null;
        inherit https;
      };
      expected = {
        http = null;
        inherit https;
      };
    };
    null-https = {
      root = {
        inherit http;
        https = null;
      };
      expected = {
        inherit http;
        https = null;
      };
    };
    runtime-http = {
      root = {inherit http https;};
      runtime.http = local;
      expected = {
        http = local;
        inherit https;
      };
    };
    runtime-https = {
      root = {inherit http https;};
      runtime.https = local;
      expected = {
        inherit http;
        https = local;
      };
    };
    runtime-instance-http = {
      root = {};
      runtime = {
        inherit http;
        instance = "main";
      };
      expected = {inherit http https;};
      expectedInstance = "main";
    };
    runtime-instance-null = {
      root.instance = "main";
      runtime.instance = null;
      expected = {
        http = null;
        https = null;
      };
      expectedInstance = null;
    };
    runtime-instance-null-keeps-root-protocols = {
      root = {
        http = null;
        inherit https;
        instance = "main";
      };
      runtime.instance = null;
      expected = {
        http = null;
        inherit https;
      };
      expectedInstance = null;
    };
    runtime-instance-null-peer = {
      root = {};
      runtime = {
        instance = "main";
        http = null;
      };
      expected = {
        http = null;
        inherit https;
      };
      expectedInstance = "main";
    };
    runtime-instance-overrides-root-instance = {
      root = {
        inherit http;
        instance = "main";
      };
      runtime.instance = "other";
      expected = {
        inherit http;
        https = local;
      };
      expectedInstance = "other";
    };
    runtime-instance-root-http = {
      root = {inherit http;};
      runtime.instance = "main";
      expected = {inherit http https;};
      expectedInstance = "main";
    };
    runtime-null-http = {
      root = {inherit http;};
      runtime.http = null;
      expected = {
        http = null;
        https = http;
      };
    };
    runtime-null-https = {
      root = {inherit https;};
      runtime.https = null;
      expected = {
        http = https;
        https = null;
      };
    };
    runtime-null-inherited-instance-https = {
      root = {
        inherit http;
        instance = "main";
      };
      runtime.https = null;
      expected = {
        inherit http;
        https = null;
      };
      expectedInstance = "main";
    };
    runtime-only-http = {
      root = {};
      runtime = {inherit http;};
      expected = {
        inherit http;
        https = http;
      };
    };
    runtime-only-https = {
      root = {};
      runtime = {inherit https;};
      expected = {
        http = https;
        inherit https;
      };
    };
    runtime-peer-keeps-root-null = {
      root = {
        http = null;
        inherit https;
      };
      runtime.https = local;
      expected = {
        http = null;
        https = local;
      };
    };
    runtime-reselect-keeps-root-protocols = {
      root = {
        http = null;
        inherit https;
        instance = "main";
      };
      runtime.instance = "other";
      expected = {
        http = null;
        inherit https;
      };
      expectedInstance = "other";
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
              other = {
                http = local;
                https = local;
              };
            };
            proxy = test.root;
          }
          // lib.genAttrs runtimes (_: {proxy = test.runtime or {};});
      }).config.ai;
    rows = lib.mapAttrsToList (scenario: test: let
      actual = observe test;
    in
      lib.concatMap (runtime: [
        (lib.nameValuePair "${scenario}: ${runtime} resolves protocols and instance"
          (actual.${runtime}.proxy == test.expected // {instance = test.expectedInstance or null;}))
        (lib.nameValuePair "${scenario}: ${runtime} normalizes only the resolved protocols"
          (actual.${runtime}.normalized.proxy == test.expected))
      ])
      runtimes)
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
      // {
        "ai.kiro.proxy.https rejects an empty string" = rejectsEmpty ["ai" "kiro" "proxy" "https"] https;
        "ai.proxy.http rejects an empty string" = rejectsEmpty ["ai" "proxy" "http"] http;
      }
    ))))
  backends;
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
    for name in codex kimchi kiro-cli; do
      ln -s proxy-sentinel "$out/bin/$name"
    done
  '';
  executable = {
    codex = "codex";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  launcherConfig = runtime: env: proxy:
    lib.recursiveUpdate (harness.setEnable runtime true) {
      ai = {
        inherit proxy;
        ${runtime} =
          if runtime == "kiro"
          then {
            cli = {
              package = sentinel;
              environmentVariables = env;
            };
          }
          else {
            package = sentinel;
            environmentVariables = env;
          };
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
        check_output 'instance supplies loopback NO_PROXY' '127.0.0.1,localhost,::1' \
          env -u NO_PROXY -u no_proxy PROXY_SENTINEL_MODE=no-proxy ${selectedInstance}/bin/${exe}
        check_proxy 'both unset protocols use their configured defaults' ${lib.escapeShellArg http} ${lib.escapeShellArg https} absent \
          env -u HTTP_PROXY -u HTTPS_PROXY ${ordinary}/bin/${exe}
        check_proxy 'ambient lowercase HTTP suppresses only the uppercase HTTP default' absent ${lib.escapeShellArg https} absent \
          env -u HTTP_PROXY -u HTTPS_PROXY http_proxy=ambient ${ordinary}/bin/${exe}
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
        lib.filter (lib.hasPrefix "ai.proxy is set but ai.${runtime}.package is null;")
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
          "absent proxy is silent without a package" = warnings null {} == [];
          "explicit null protocols are silent without a package" =
            warnings null {
              http = null;
              https = null;
            }
            == [];
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
    copilot = proxy:
      lib.filter (lib.hasInfix "ai.proxy is set but ${backend} does not deliver it to copilot")
      (evaluate {
        ai = {
          inherit proxy;
          copilot.enable = true;
        };
      }).config.warnings;
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
      "Copilot explicit null protocols are not a delivery request" =
        copilot {
          http = null;
          https = null;
        }
        == [];
      "Copilot omitted proxy fields do not warn" = copilot {} == [];
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
    inherited = failures {inherit http;} {};
    optOut = {
      http = null;
      https = null;
    };
  in
    lib.nameValuePair "module-${name}" (mkTest name (checkRows name {
      "explicit null protocols permit tracking with a root instance" = failures {instance = "main";} optOut == [];
      "explicit null protocols permit tracking with a root protocol" = failures {inherit http;} optOut == [];
      "inherited HTTP proxy reports the tracking conflict and opt-out remedy" =
        builtins.length inherited
        == 1
        && lib.hasPrefix "ai.kiro.cli.usageTracking owns HTTP(S)/ALL/NO_PROXY" (builtins.head inherited)
        && lib.hasInfix "ai.kiro.proxy = {http = null; https = null;}" (builtins.head inherited);
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
        evaluate = backend: native:
          backends.${backend} {
            ai = {
              proxy = {inherit http;};
              kimchi = {
                enable = true;
                native.harnessSettings = native;
              };
            };
          };
        delivered = native: let
          result = evaluate "hm" native;
          path = "${result.config.ai.kimchi.configDir}/harness/settings.json";
        in
          result.config.ai.files.${path}.content.value.httpProxy or null;
      in
        mkTest name (checkRows name {
          "devenv shared proxy leaves native httpProxy unset" = (evaluate "devenv" {}).config.ai.kimchi.native.harnessSettings.httpProxy == null;
          "home manager shared proxy leaves native httpProxy unset" = (evaluate "hm" {}).config.ai.kimchi.native.harnessSettings.httpProxy == null;
          "native null does not deliver a proxy origin in settings" = delivered {httpProxy = null;} == null;
          "native proxy reaches settings instead of the shared origin" = delivered {httpProxy = local;} == local;
          "shared proxy is not written to native settings" = delivered {} == null;
        });
    };
}
