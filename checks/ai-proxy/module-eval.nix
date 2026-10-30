{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  http = "http://plain.invalid:8080";
  https = "http://secure.invalid:8443";
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
  };
  semantics = lib.concatMapAttrs (backend: evaluate:
    lib.mapAttrs' (name: test:
      lib.nameValuePair "module-ai-proxy-${backend}-${name}"
      (mkTest "ai-proxy-${backend}-${name}" (let
        result = evaluate {
          ai = {proxy = test.root;} // lib.genAttrs runtimes (_: {proxy = test.runtime or {};});
        };
      in
        lib.all (runtime:
          result.config.ai.${runtime}.proxy
          == test.expected
          && result.config.ai.${runtime}.normalized.proxy == test.expected)
        runtimes)))
    cases)
  backends;
  invalidProxies = lib.concatMapAttrs (backend: evaluate:
    lib.mapAttrs' (name: path:
      lib.nameValuePair "module-ai-proxy-${backend}-${name}"
      (mkTest "ai-proxy-${backend}-${name}" (let
        value = lib.attrByPath path null (evaluate (lib.setAttrByPath path "")).config;
      in
        !(builtins.tryEval (builtins.deepSeq value value)).success))) {
      reject-empty-root-http = ["ai" "proxy" "http"];
      reject-empty-runtime-https = ["ai" "kiro" "proxy" "https"];
    })
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
    printf '%s\n' "''${HTTP_PROXY-absent}" "''${HTTPS_PROXY-absent}" "''${https_proxy-absent}"
    EOF
    chmod +x "$out/bin/proxy-sentinel"
    for name in codex kimchi kiro-cli kiro-cli-chat; do
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
              v3 = true;
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
      kimchiNative = installedConfig (lib.recursiveUpdate (launcherConfig runtime {} {inherit http https;}) {
        ai.kimchi.native.harnessSettings.httpProxy = local;
      });
      kiroV2 = installedConfig (lib.recursiveUpdate (launcherConfig runtime {} {inherit http https;}) {
        ai.kiro.cli.v3 = false;
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
        expected=$(printf '%s\n' ${lib.escapeShellArg http} ${lib.escapeShellArg https} absent)
        actual=$(env -u HTTP_PROXY -u HTTPS_PROXY ${ordinary}/bin/${exe})
        test "$actual" = "$expected"
        expected=$(printf '%s\n' absent ${lib.escapeShellArg https} absent)
        actual=$(env -u HTTP_PROXY -u HTTPS_PROXY http_proxy=ambient ${ordinary}/bin/${exe})
        test "$actual" = "$expected"
        expected=$(printf '%s\n' ${lib.escapeShellArg http} ${lib.escapeShellArg http} absent)
        actual=$(env -u HTTP_PROXY -u HTTPS_PROXY ${sameProtocol}/bin/${exe})
        test "$actual" = "$expected"
        expected=$(printf '%s\n' ambient "" absent)
        actual=$(HTTP_PROXY=ambient HTTPS_PROXY= ${ordinary}/bin/${exe})
        test "$actual" = "$expected"
        expected=$(printf '%s\n' ${lib.escapeShellArg local} "" absent)
        actual=$(HTTP_PROXY=ambient HTTPS_PROXY=ambient ${native}/bin/${exe})
        test "$actual" = "$expected"
        expected=$(printf '%s\n' ${lib.escapeShellArg http} absent ${lib.escapeShellArg local})
        actual=$(env -u HTTP_PROXY -u HTTPS_PROXY ${nativeLowercase}/bin/${exe})
        test "$actual" = "$expected"
        ${lib.optionalString (runtime == "kimchi" && backend == "hm") ''
          expected=$(printf '%s\n' absent absent absent)
          actual=$(env -u HTTP_PROXY -u HTTPS_PROXY ${kimchiNative}/bin/${exe})
          test "$actual" = "$expected"
        ''}
        ${lib.optionalString (runtime == "kiro") ''
          expected=$(printf '%s\n' absent absent absent)
          actual=$(env -u HTTP_PROXY -u HTTPS_PROXY ${kiroV2}/bin/${exe})
          test "$actual" = "$expected"
        ''}
        echo PASS > "$out"
      ''))
    executable)
  backends;
  packageWarnings = lib.concatMapAttrs (backend: evaluate:
    lib.listToAttrs (map (runtime: let
      name = "ai-proxy-${backend}-${runtime}-null-package-warning";
      warning = "ai.proxy is set but ai.${runtime}.package is null; the proxy is delivered only through the managed launcher.";
      warnings = package: proxy:
        lib.filter (lib.hasInfix warning)
        (evaluate {
          ai = {
            inherit proxy;
            ${runtime} = {
              enable = true;
              inherit package;
            };
          };
        }).config.warnings;
    in
      lib.nameValuePair "module-${name}" (mkTest name (
        warnings null {inherit http;}
        == [warning]
        && warnings sentinel {inherit http;} == []
        && warnings null {} == []
        && warnings null {
          http = null;
          https = null;
        }
        == []
      ))) ["codex" "kimchi"]))
  backends;
  settings = lib.mapAttrs' (backend: evaluate:
    lib.nameValuePair "module-ai-proxy-${backend}-settings-and-warnings"
    (mkTest "ai-proxy-${backend}-settings-and-warnings" (let
      claude = native:
        evaluate {
          ai = {
            proxy = {inherit http https;};
            claude = {
              enable = true;
              native.settings.env = native;
            };
          };
        };
      settings = claudeSettings (claude {});
      overridden = claudeSettings (claude {
        HTTP_PROXY = local;
        HTTPS_PROXY = local;
      });
      blocked = claudeSettings (evaluate {
        ai = {
          proxy = {
            http = null;
            inherit https;
          };
          claude.enable = true;
        };
      });
      copilot = proxy:
        (evaluate {
          ai = {
            inherit proxy;
            copilot.enable = true;
          };
        }).config.warnings;
      warning = "ai.proxy is set but ${backend} does not deliver it to copilot";
    in
      settings.env.HTTP_PROXY
      == http
      && settings.env.HTTPS_PROXY == https
      && overridden.env.HTTP_PROXY == local
      && overridden.env.HTTPS_PROXY == local
      && !(blocked.env ? HTTP_PROXY)
      && blocked.env.HTTPS_PROXY == https
      && lib.any (lib.hasInfix warning) (copilot {inherit http;})
      && !(lib.any (lib.hasInfix warning) (copilot {
        http = null;
        https = null;
      }))
      && !(lib.any (lib.hasInfix warning) (copilot {})))))
  backends;
  kiroWarnings = lib.mapAttrs' (backend: evaluate:
    lib.nameValuePair "module-ai-proxy-${backend}-kiro-engine-warning"
    (mkTest "ai-proxy-${backend}-kiro-engine-warning" (let
      warnings = v3: root: proxy:
        unverified
        (evaluate {
          ai = {
            proxy = root;
            kiro = {
              inherit proxy;
              cli = {
                enable = true;
                inherit v3;
              };
            };
          };
        }).config.warnings;
      unverified = lib.filter (lib.hasInfix "Kiro v2 model-request proxy consumption is unverified");
      once = field: messages:
        builtins.length messages
        == 1
        && lib.hasInfix "ai.kiro.proxy.${field} is set" (builtins.head messages);
      singleHttp = {
        inherit http;
        https = null;
      };
      v2 = warnings false {inherit http;} {};
    in
      builtins.length v2
      == 2
      && once "http" (lib.filter (lib.hasInfix ".http is set") v2)
      && once "https" (lib.filter (lib.hasInfix ".https is set") v2)
      && once "http" (warnings false singleHttp {})
      && once "http" (warnings false {} singleHttp)
      && warnings true singleHttp {} == []
      && warnings true {} singleHttp == []
      && warnings false {inherit http;} {
        http = null;
        https = null;
      }
      == [])))
  backends;
  usageTracking = lib.mapAttrs' (backend: evaluate:
    lib.nameValuePair "module-ai-proxy-${backend}-kiro-usage-tracking"
    (mkTest "ai-proxy-${backend}-kiro-usage-tracking" (let
      evaluateProxy = proxy:
        evaluate {
          ai = {
            proxy = {inherit http;};
            kiro = {
              inherit proxy;
              cli = {
                enable = true;
                usageTracking.enable = true;
                v3 = true;
              };
            };
          };
        };
      failures = map (entry: entry.message) (lib.filter (entry: !entry.assertion) (evaluateProxy {}).config.assertions);
      optedOut = evaluateProxy {
        http = null;
        https = null;
      };
    in
      builtins.length failures
      == 1
      && lib.hasInfix "usageTracking owns HTTP(S)/ALL/NO_PROXY" (builtins.head failures)
      && lib.hasInfix "ai.kiro.proxy = {http = null; https = null;}" (builtins.head failures)
      && lib.all (entry: entry.assertion) optedOut.config.assertions)))
  backends;
in {
  checks =
    semantics
    // invalidProxies
    // kiroWarnings
    // launchers
    // packageWarnings
    // settings
    // usageTracking
    // {
      module-ai-proxy-kimchi-native-priority = mkTest "ai-proxy-kimchi-native-priority" (let
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
        lib.all (backend: (evaluate backend {}).config.ai.kimchi.native.harnessSettings.httpProxy == null) (builtins.attrNames backends)
        && delivered {} == null
        && delivered {httpProxy = local;} == local
        && delivered {httpProxy = null;} == null);
    };
}
