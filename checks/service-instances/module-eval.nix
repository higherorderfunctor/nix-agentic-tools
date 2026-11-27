# cspell:ignore ADMINKEYFILE DATAKEYFILE MANAGEMENTKEYFILE
# `ai.<owner>.instances` for CLIProxyAPI and CPA Manager Plus through the
# shared helper (packages/ai-module/lib/instances.nix): each instance is one
# `ai.services` entry with a rendered config file, on both backends.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) checkRows claudeSettings evalDevenv evalHm launchdAgentRunsLauncher mkTest rejectsChange;
  redact = import ../../lib/redact {inherit lib;};
  services = import ../../packages/ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../lib/strict-shell-application.nix;

  adminKey = redact.file "/run/secrets/cpa-admin-key";
  clientKey = redact.file "/run/secrets/cpa-client-key";
  managementKey = redact.file "/run/secrets/cpa-management-key";
  placeholder = name: "{" + "$" + name + "}";
  declared = {
    cliproxyapi.instances.main = {
      port = 8400;
      settings = {
        access.api-keys = [clientKey];
        management.secret-key = managementKey;
      };
    };
    cpa-manager-plus.instances.main = {
      port = 18400;
      upstream = "main";
    };
  };
  withInstances = ai: {ai = lib.recursiveUpdate declared ai;};
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  stateRoot = {
    devenv = "/tmp/devenv-state";
    hm = "/home/test/.local/state";
  };
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);

  expectedProxyConfig = backend: disablePanelUpdates: {
    access.api-keys = [(placeholder "CLIPROXYAPI_ACCESS_API_KEYS_0")];
    management = {
      # The panel is not downloaded unprompted unless a consumer asks.
      disable-auto-update-panel = disablePanelUpdates;
      secret-key = placeholder "CLIPROXYAPI_MANAGEMENT_SECRET_KEY";
    };
    oauth.auth-dir = "${stateRoot.${backend}}/cliproxyapi/main/auth";
    server = {
      host = "127.0.0.1";
      port = 8400;
    };
  };

  # The service entries and claims both backends share.
  entries = backend: let
    result = evaluate backend (withInstances {});
    inherit (result) config;
    proxy = config.ai.services.cliproxyapi-main;
    manager = config.ai.services.cpa-manager-plus-main;
    root = stateRoot.${backend};
  in
    proxy.files.config.variable
    == "CPA_CONFIG"
    && proxy.files.config.secrets
    == {
      CLIPROXYAPI_ACCESS_API_KEYS_0 = clientKey;
      CLIPROXYAPI_MANAGEMENT_SECRET_KEY = managementKey;
    }
    && builtins.fromJSON proxy.files.config.content == expectedProxyConfig backend true
    && !config.ai.cliproxyapi.instances.main.fetchModelCatalogs
    && proxy.environment == {}
    && lib.hasSuffix "/bin/cliproxyapi-main" (lib.head proxy.command)
    && services.triggers proxy == ["/run/secrets/cpa-client-key" "/run/secrets/cpa-management-key"]
    && manager.files.config.variable == "CPA_MANAGER_CONFIG"
    && manager.files.config.secrets == {}
    && builtins.fromJSON manager.files.config.content
    == {
      cpaUpstreamUrl = "http://127.0.0.1:8400";
      dataDir = "${root}/cpa-manager-plus/main";
      httpAddr = "127.0.0.1:18400";
    }
    && manager.environment == {CPA_MANAGEMENT_KEY = managementKey;}
    && config.ai.claims.port
    == {
      "18400" = ["cpa-manager-plus:cpa-manager-plus-main.ports.main"];
      "8400" = ["cliproxyapi:cliproxyapi-main.ports.main"];
    }
    && failures result == [];

  # Read the merged fields for type and merge errors, and force the real
  # service render for assertion cases that still produce a file.
  proxySettings = backend: let
    evaluateSettings = settings: evaluate backend (withInstances {cliproxyapi.instances.main = {inherit settings;};});
    merged = settings: (evaluateSettings settings).config.ai.cliproxyapi.instances.main.settings;
    observes = settings: matchesRender: expectedFailures: let
      result = evaluateSettings settings;
      rendered = builtins.fromJSON result.config.ai.services.cliproxyapi-main.files.config.content;
      # An unexpected throw must fail the named row, not bypass checkRows.
      observed = builtins.tryEval (matchesRender rendered && failures result == expectedFailures);
    in
      observed.success && observed.value;
    ruleOf = settings: lib.head (lib.head settings.access.key-allowlist).credentials;
    allowing = rule: {
      access.key-allowlist = [
        {
          api-key = clientKey;
          credentials = [
            ({
                kind = "apikey";
                provider = "claude";
              }
              // rule)
          ];
        }
      ];
    };
    accepts = settings: read: expected: observes settings (rendered: read rendered == expected) [];
    acceptsRule = settings: expected:
      accepts settings (config: config.access.key-allowlist) [
        {
          api-key = placeholder "CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_API_KEY";
          credentials = [expected];
        }
      ];
    refuses = settings: message:
      observes settings builtins.isAttrs ["ai.cliproxyapi.instances.main: ${message}"];
    # A list of only `mkIf false` elements passes the type's definition check
    # but merges to [], which CPA reads as unrestricted; assert on that value.
    emptied = field:
      refuses (allowing {${field} = [(lib.mkIf false "x")];}) "settings.access.key-allowlist[].credentials[].${field} merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value.";
    narrowing = field: expected: invalid:
      rejectsChange (settings: (ruleOf (merged settings)).${field}) {
        inherit expected;
        invalid = allowing {${field} = invalid;};
        valid = allowing {${field} = expected;};
      };
    nullEntry = entries:
      refuses {access.key-allowlist = entries;} "settings.access.key-allowlist has a null entry, which the renderer drops: a list of only nulls renders as [] and switches enforcement off for every key. Remove the null entry, or set the list to [] to switch the allowlist off.";
    oauth.kind = "oauth";
    urls = ["https://api.z.ai/api/anthropic"];
  in
    checkRows "${backend}: CLIProxyAPI settings" {
      # Valid merges and rendered members.
      "allowlist switched off" = accepts {access.key-allowlist = [];} (config: config.access.key-allowlist) [];
      "apikey rule narrowed by base-urls and ids" =
        acceptsRule (allowing {
          base-urls = urls;
          ids = ["claude-apikey"];
        }) {
          base-urls = urls;
          ids = ["claude-apikey"];
          kind = "apikey";
          provider = "claude";
        };
      "default loopback host can be overridden" = accepts {server.host = "192.0.2.1";} (config: config.server.host) "192.0.2.1";
      "mkIf lists that keep an element" = let
        elements = [(lib.mkIf true "x") (lib.mkIf false "y")];
      in
        acceptsRule (allowing {
          base-urls = elements;
          ids = elements;
        }) {
          base-urls = ["x"];
          ids = ["x"];
          kind = "apikey";
          provider = "claude";
        };
      "oauth rule narrowed by ids" = acceptsRule (allowing (oauth // {ids = ["claude-oauth"];})) {
        ids = ["claude-oauth"];
        kind = "oauth";
        provider = "claude";
      };
      "panel updater can be enabled" = accepts {management.disable-auto-update-panel = false;} lib.id (expectedProxyConfig backend false);
      "plugins without an allowlist" = accepts {plugins.enabled = true;} (config: config.plugins.enabled) true;

      # Invalid settings that reach the assertion layer.
      "base-urls emptied by mkIf" = emptied "base-urls";
      "ids emptied by mkIf" = emptied "ids";
      # An all-null list renders as off; a mixed list catches a guard that
      # only rejects lists that become empty.
      "null allowlist entry" = nullEntry [null];
      "null allowlist entry beside a rule" = nullEntry ([null] ++ (allowing {}).access.key-allowlist);
      "oauth rule with base-urls" = refuses (allowing (oauth // {base-urls = urls;})) "settings.access.key-allowlist has a rule with kind = \"oauth\" and base-urls, which can never match: base-urls compare an API-key credential's base URL and never match an OAuth login. Use kind = \"apikey\" or drop base-urls.";
      # Its one failure also proves a bare rule, with no ids or base-urls, passes.
      "plugins beside the allowlist" = refuses (allowing oauth // {plugins.enabled = true;}) "settings.plugins.enabled = true voids settings.access.key-allowlist: plugin executors choose credentials outside it and can read every credential through host.auth.get. Disable plugins or drop the allowlist.";

      # Invalid definitions: the paired control forces the same option.
      "base-urls cannot be empty" = narrowing "base-urls" urls [];
      "base-urls cannot contain null" = narrowing "base-urls" urls [null];
      "ids cannot be empty" = narrowing "ids" ["claude-apikey"] [];
      "ids cannot contain null" = narrowing "ids" ["claude-apikey"] [null];
      "kind must name a credential kind" = rejectsChange (settings: (ruleOf (merged settings)).kind) {
        expected = "apikey";
        invalid = allowing {kind = "wrong";};
        valid = allowing {};
      };
      "port must match the instance port" = rejectsChange (settings: (merged settings).server.port) {
        expected = 8400;
        invalid.server.port = 9999;
        valid.server.port = 8400;
      };
      "the client key must be a reference" = rejectsChange (settings: (merged settings).access.api-keys) {
        expected = [clientKey];
        invalid.access.api-keys = ["plain-client-key"];
        valid.access.api-keys = [clientKey];
      };
    };

  managerRestrictions = backend: let
    observe = ai: failures (evaluate backend (withInstances ai));
    uncleanState = "/srv/state/../manager";
    unclean = {
      config.dbPath = "usage.sqlite";
      environment = {
        USAGE_DATA_DIR = "/srv/manager/";
        USAGE_DB_PATH = "/srv/manager/usage.sqlite${builtins.fromJSON ''"\u00a0"''}";
      };
    };
    pathMessage = option: value: "ai.cpa-manager-plus.instances.main.${option}: with settings.config.adminKeyFile set, must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, which Manager Plus opens as written; not `${value}`.";
  in
    checkRows "${backend}: Manager Plus restrictions" {
      # Each other admin key form is steered to adminKeyFile, never ignored.
      "admin key variables are refused" =
        observe {
          cpa-manager-plus.instances.main.settings = {
            config.adminKeyFile = adminKey;
            environment = {
              CPA_MANAGER_ADMIN_KEY = adminKey;
              CPA_MANAGER_ADMIN_KEY_FILE = adminKey;
            };
          };
        }
        == [
          "ai.cpa-manager-plus.instances.main.settings.environment.CPA_MANAGER_ADMIN_KEY: set settings.config.adminKeyFile instead; Manager Plus reads CPA_MANAGER_ADMIN_KEY only on its first start, while the instance applies adminKeyFile on every start."
          "ai.cpa-manager-plus.instances.main.settings.environment.CPA_MANAGER_ADMIN_KEY_FILE: set settings.config.adminKeyFile instead; Manager Plus reads CPA_MANAGER_ADMIN_KEY_FILE only on its first start, while the instance applies adminKeyFile on every start."
        ];
      # With adminKeyFile, every input that places the database must be a path
      # Manager Plus opens as written; without it, none is refused.
      "database paths must be used as written with adminKeyFile" =
        observe {
          cpa-manager-plus.instances.main = {
            settings = unclean // {config = unclean.config // {adminKeyFile = adminKey;};};
            stateDir = uncleanState;
          };
        }
        == [
          (pathMessage "settings.config.dataDir" uncleanState)
          (pathMessage "settings.config.dbPath" unclean.config.dbPath)
          (pathMessage "settings.environment.USAGE_DATA_DIR" unclean.environment.USAGE_DATA_DIR)
          (pathMessage "settings.environment.USAGE_DB_PATH" unclean.environment.USAGE_DB_PATH)
        ];
      "database paths used as written work with adminKeyFile" =
        observe {
          cpa-manager-plus.instances.main = {
            settings = {
              config = {
                adminKeyFile = adminKey;
                dbPath = "/srv/manager/usage.sqlite";
              };
              environment = {
                USAGE_DATA_DIR = "/srv/manager";
                USAGE_DB_PATH = "/srv/manager/usage.sqlite";
              };
            };
            stateDir = "/srv/state/manager";
          };
        }
        == [];
      "database paths without adminKeyFile are not restricted" =
        observe {
          cpa-manager-plus.instances.main = {
            settings = unclean;
            stateDir = uncleanState;
          };
        }
        == [];
      "upstream must be enabled" =
        observe {cliproxyapi.instances.main.enable = false;}
        == ["ai.cpa-manager-plus.instances.main.upstream names `ai.cliproxyapi.instances.main`, which is disabled."];
      "upstream must name a declared instance" =
        observe {cpa-manager-plus.instances.main.upstream = "missing";}
        == ["ai.cpa-manager-plus.instances.main.upstream names `missing`, which is not an `ai.cliproxyapi.instances` entry."];
    };

  # Secret-file settings (redact.types.secretFile) must retain the file tag
  # when lifted into a config file or environment. Delivery is checked in
  # packages/ai-module/checks.
  secretFiles = let
    asFile = value: {_redact.asFile = value;};
    dataKey = redact.command "/run/current-system/sw/bin/read-data-key";
    joined = redact.concat [managementKey];
    tlsKey = redact.file "/run/secrets/tls.key";
    servicesFor = input: (evalHm (withInstances input)).config.ai.services;
    proxyFile = input: (servicesFor {cliproxyapi.instances.main.settings = input;}).cliproxyapi-main.files.config;
    pluginToken = token: {plugins.configs.example = {inherit token;};};
    pluginVariable = "CLIPROXYAPI_PLUGINS_CONFIGS_EXAMPLE_TOKEN";
  in
    checkRows "service-instances secret files" {
      "a TLS key is a secret file" = let
        file = proxyFile {
          server.tls = {
            cert = "/etc/cliproxyapi/tls.crt";
            enable = true;
            key = tlsKey;
          };
        };
      in
        file.secrets.CLIPROXYAPI_SERVER_TLS_KEY == asFile tlsKey;
      "manager key files are secret files" = let
        manager =
          (servicesFor {
            cpa-manager-plus.instances.main.settings = {
              config = {
                adminKeyFile = adminKey;
                dataKeyFile = dataKey;
                # Manager Plus writes the key it generates here; this stays a path.
                dataKeyPath = "/srv/manager/data.key";
                managementKeyFile = joined;
              };
              environment = {
                CPA_MANAGEMENT_KEY_FILE = joined;
                CPA_MANAGER_DATA_KEY_FILE = dataKey;
                CPA_MANAGER_DATA_KEY_PATH = "/srv/manager/data.key";
              };
            };
          }).cpa-manager-plus-main;
      in
        manager.environment
        == {
          CPA_MANAGEMENT_KEY = managementKey;
          CPA_MANAGEMENT_KEY_FILE = asFile joined;
          CPA_MANAGER_DATA_KEY_FILE = asFile dataKey;
          CPA_MANAGER_DATA_KEY_PATH = "/srv/manager/data.key";
        }
        && manager.files.config.secrets
        == {
          CPA_MANAGER_PLUS_ADMINKEYFILE = asFile adminKey;
          CPA_MANAGER_PLUS_DATAKEYFILE = asFile dataKey;
          CPA_MANAGER_PLUS_MANAGEMENTKEYFILE = asFile joined;
        };
      "untyped plugin JSON lifts references" = (proxyFile (pluginToken tlsKey)).secrets.${pluginVariable} == tlsKey;
      "untyped plugin JSON refuses malformed markers" = rejectsChange (token: (builtins.fromJSON (proxyFile (pluginToken token)).content).plugins.configs.example.token) {
        expected = placeholder pluginVariable;
        invalid._redact.concat = ["literal"];
        valid = tlsKey;
      };
    };

  # adminKeyFile alone, with no upstream management key, still waits for the
  # secret providers; `disabled` has neither and stays a plain unit.
  standalone =
    (evalHm (withInstances {
      cpa-manager-plus.instances.main = {
        settings.config.adminKeyFile = adminKey;
        upstream = null;
      };
    })).config;
  devenv = (evalDevenv (withInstances {})).config;
  hm = (evalHm (withInstances {})).config;
  disabled =
    (evalHm (withInstances {
      cliproxyapi.instances.main.enable = false;
      cpa-manager-plus.instances.main.upstream = null;
    })).config;

  # A stand-in CLIProxyAPI that reports its argv, working directory, config
  # and auth directory mode, run through the real launcher and run script.
  fakeProxy = strictShellApplication pkgs {
    name = "cliproxyapi";
    text = ''
      printf '%s\n' "$*" "$PWD" > "$RECEIVED/argv"
      ${pkgs.coreutils}/bin/cp "$2" "$RECEIVED/config.json"
      ${pkgs.coreutils}/bin/stat -c '%a' "$PWD" "$PWD/auth" > "$RECEIVED/modes"
    '';
  };
  # A stand-in Manager Plus that records the environment of each call, the
  # reset and the daemon.
  fakeManager = strictShellApplication pkgs {
    name = "cpa-manager-plus";
    text = ''
      call="''${1:-daemon}"
      ${pkgs.coreutils}/bin/env > "$RECEIVED/$call.env"
    '';
  };
  managed =
    (evalHm (withInstances {
      cpa-manager-plus.instances.main = {
        package = fakeManager;
        settings.config.adminKeyFile = redact.file "/build/admin-key";
        stateDir = "/build/state/managed";
        upstream = null;
      };
    })).config;
  runnableFor = overrides:
    (evalHm (withInstances {
      cliproxyapi.instances.main =
        lib.recursiveUpdate {
          package = fakeProxy;
          settings = {
            access.api-keys = [(redact.file "/build/client-key")];
            management.secret-key = redact.file "/build/management-key";
          };
          stateDir = "/build/state/main";
        }
        overrides;
    })).config;
  runnable = runnableFor {};
  # The same stand-in with the model catalog fetches and the panel updater
  # turned back on.
  phoneHomeOn = runnableFor {
    fetchModelCatalogs = true;
    settings.management.disable-auto-update-panel = false;
  };

  cliproxyapi = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  # A client key read at start from /build/key-<name>, and its allowlist entry
  # with one API-key rule.
  fileKey = name: redact.file "/build/key-${name}";
  allow = name: rule: {
    api-key = fileKey name;
    credentials = [({kind = "apikey";} // rule)];
  };
  daemonInstance = port: names: settings: {
    inherit port;
    package = cliproxyapi;
    settings =
      settings
      // {
        access = settings.access // {api-keys = map fileKey names;};
      };
    stateDir = "/build/state/${toString port}";
  };

  # A stand-in upstream's key, read at start from /build/upstream-<name>.
  upstreamKey = name: redact.file "/build/upstream-${name}";
  # The claude executor appends /v1/messages to the base URL itself.
  claudeBaseURL = port: "http://127.0.0.1:${toString port}";
  # Run packaged CPA against stand-ins; each successful request must reach
  # exactly its named upstream with that upstream's credential.
  # cspell:ignore healthz
  keyAllowlistCheck = {
    ai,
    name,
    port,
    requests,
    upstreams,
    verify ? _: "",
  }: let
    proxy =
      (evalHm (lib.recursiveUpdate {
        ai.cliproxyapi.instances.main = {
          package = cliproxyapi;
          inherit port;
          stateDir = "/build/state/cpa";
        };
      } {inherit ai;})).config;
  in
    pkgs.runCommandLocal "module-test-service-instances-${name}" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      for name in a b other; do printf '%s' "key-$name" > "/build/key-$name"; done
      ${verify proxy}
      ${daemonHarness name}
      upstreams=(${lib.escapeShellArgs upstreams})
      for upstream in "''${upstreams[@]}"; do
        IFS=: read -r name port path <<< "$upstream"
        printf '%s' "upstream-$name" > "/build/upstream-$name"
        ${pkgs.python3}/bin/python3 ${./stand-in-upstream.py} "$name" "$port" "$name.log" 2> "$name.err" &
        processes+=("$!")
        ready "$!" "http://127.0.0.1:$port/" "$name.err"
      done
      ${proxy.systemd.user.services.cliproxyapi-main.Service.ExecStart} > cpa.log 2>&1 &
      processes+=("$!")
      ready "$!" http://127.0.0.1:${toString port}/healthz cpa.log
      request() {
        local status=$1 answer=$2 api=$3 model=$4 key=$5 code path data filter
        case "$api" in
          anthropic) path=/v1/messages filter='.content[0].text == $answer' data="{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" ;;
          chat) path=/v1/chat/completions filter='.choices[0].message.content == $answer' data="{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" ;;
          responses) path=/v1/responses filter='.output[0].content[0].text == $answer' data="{\"model\":\"$model\",\"input\":\"hi\"}" ;;
        esac
        code=$(${pkgs.curl}/bin/curl --noproxy '*' --max-time 10 --silent --output response.json --write-out '%{http_code}' \
          --header 'Content-Type: application/json' --header "Authorization: Bearer $key" \
          --data "$data" "http://127.0.0.1:${toString port}$path")
        if [ "$status" != 200 ]; then
          filter='(.error.message? // .error? // "") | contains($answer)'
        fi
        if [ "$code" != "$status" ] || ! ${pkgs.jq}/bin/jq -e --arg answer "$answer" "$filter" response.json > /dev/null 2>&1; then
          echo "FAIL: $key, $api $model: $code, want $status $answer" >&2
          cat response.json cpa.log >&2
          return 1
        fi
        echo "ok: $key, $api $model: $code $answer"
      }
      ${requests}
      for upstream in "''${upstreams[@]}"; do
        IFS=: read -r name port path <<< "$upstream"
        test "$(cat "$name.log")" = "$path Bearer upstream-$name"
        echo "ok: $name received one call with its own credential"
      done
      touch "$out"
    '';

  # Shell for a check that starts real daemons: each started process joins
  # `processes` and is killed on exit; `ready <pid> <url> <log>` polls `url`
  # into health.json and prints the log if the process dies first.
  # The user manager sets XDG_RUNTIME_DIR and INVOCATION_ID for every unit.
  daemonHarness = invocation: ''
    export HOME="$TMPDIR/home" XDG_RUNTIME_DIR="$TMPDIR/run" INVOCATION_ID=${invocation}
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    processes=()
    cleanup() {
      for pid in "''${processes[@]}"; do kill -KILL "$pid" 2>/dev/null || :; done
      wait || :
    }
    trap cleanup EXIT
    ready() {
      local pid=$1 url=$2 log=$3
      for attempt in {1..100}; do
        # cspell:ignore noproxy
        if ${pkgs.curl}/bin/curl --noproxy '*' --max-time 1 --silent --fail "$url" > health.json; then
          return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      cat "$log" >&2
      echo "service did not become ready: $url" >&2
      return 1
    }
  '';
in {
  checks =
    {
      module-service-instances = mkTest "service-instances" (
        secretFiles
        && checkRows "service-instances backends" {
          devenv = entries "devenv" && proxySettings "devenv" && managerRestrictions "devenv";
          hm = entries "hm" && proxySettings "hm" && managerRestrictions "hm";
        }
        && devenv.processes.cliproxyapi-main.watch.paths == ["/run/secrets/cpa-client-key" "/run/secrets/cpa-management-key"]
        && devenv.processes.cpa-manager-plus-main.watch.paths == ["/run/secrets/cpa-management-key"]
        && !disabled.ai.services.cliproxyapi-main.enable
        && disabled.ai.claims.port."8400" == ["cliproxyapi:cliproxyapi-main.ports.main"]
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # Start the packaged daemons through the actual instance-derived units,
      # with file references whose dummy values exist only at build time.
      module-service-instances-real-daemons = let
        daemons = manager:
          (evalHm (withInstances {
            cliproxyapi.instances.main = {
              package = cliproxyapi;
              port = 28417;
              settings = {
                access.api-keys = [(redact.file "/build/client-key")];
                management.secret-key = redact.file "/build/management-key";
              };
              stateDir = "/build/state/cpa";
            };
            cpa-manager-plus.instances.main =
              {
                package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-manager-plus;
                port = 28418;
                settings.config.adminKeyFile = redact.file "/build/admin-key";
                stateDir = "/build/state/manager";
              }
              // manager;
          })).config;
        real = daemons {};
        # The same daemon with a declared database outside its state, and a
        # dark panel default.
        declaredDatabase = daemons {
          settings = {
            config = {
              adminKeyFile = redact.file "/build/admin-key";
              defaultTheme = "dark";
            };
            environment.USAGE_DB_PATH = "/build/state/declared-db/usage.sqlite";
          };
          stateDir = "/build/state/declared";
        };
      in
        pkgs.runCommandLocal "module-test-service-instances-real-daemons" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s' client-test-secret > /build/client-key
          printf '%s' management-test-secret > /build/management-key
          printf '%s\n' admin-key-a > /build/admin-key
          ${daemonHarness "real-daemons"}
          ${real.systemd.user.services.cliproxyapi-main.Service.ExecStart} > cpa.log 2>&1 &
          processes+=("$!")
          ready "''${processes[0]}" http://127.0.0.1:28417/healthz cpa.log
          ${pkgs.jq}/bin/jq -e '.status == "ok"' health.json
          grep -F 'Local model mode' cpa.log
          main=${real.systemd.user.services.cpa-manager-plus-main.Service.ExecStart}
          declared=${declaredDatabase.systemd.user.services.cpa-manager-plus-main.Service.ExecStart}
          manager() {
            "$1" > "$2" 2>&1 &
            processes+=("$!")
            ready "$!" http://127.0.0.1:28418/health "$2"
          }
          stop() {
            kill -TERM "''${processes[-1]}"
            wait "''${processes[-1]}" || :
          }
          # The panel's pre-login info carries defaultTheme, which the served
          # web app reads (patches/default-theme.patch).
          theme() {
            ${pkgs.curl}/bin/curl --noproxy '*' --max-time 5 --silent --fail http://127.0.0.1:28418/usage-service/info > info.json
            echo "defaultTheme: $(${pkgs.jq}/bin/jq -c .defaultTheme info.json)"
            ${pkgs.jq}/bin/jq -e --arg theme "$1" '.defaultTheme == $theme' info.json > /dev/null
          }
          # A start refuses a key that is blank to strings.TrimSpace, here a
          # lone no-break space, before bootstrap could generate and log a key.
          printf '\302\240\n' > /build/admin-key
          if "$main" > blank.log 2>&1; then
            echo "a blank admin key file started Manager Plus" >&2
            exit 1
          fi
          ${pkgs.gnugrep}/bin/grep -F 'settings.config.adminKeyFile: the key is blank to strings.TrimSpace' blank.log
          printf '%s\n' admin-key-a > /build/admin-key
          manager "$main" manager.log
          ${pkgs.jq}/bin/jq -e '.ok == true and .service == "cpa-manager-plus"' health.json
          theme auto
          ${pkgs.curl}/bin/curl --noproxy '*' --max-time 5 --silent --fail http://127.0.0.1:28418/management.html > panel.html
          # An assignment fails on grep's status, so a panel without it fails here.
          count="$(${pkgs.gnugrep}/bin/grep -cF defaultTheme panel.html)"
          echo "served panel lines reading defaultTheme: $count"
          # Each port has exactly one listener, bound to IPv4 loopback.
          for port in 6F01 6F02; do
            ${pkgs.gawk}/bin/awk -v port="$port" '
              $4 == "0A" && $2 ~ ":" port "$" {
                count++
                if ($2 != "0100007F:" port) exit 1
                print "loopback listener: " $2
              }
              END { if (count != 1) exit 1 }
            ' /proc/net/tcp /proc/net/tcp6
          done
          # The web login's admin check: GET /v0/management/config with the
          # admin key as a bearer token (useAuthStore login → configApi), which
          # A valid key loads the configuration; Manager Plus answers 401
          # "invalid admin key" for any other key.
          request() {
            ${pkgs.curl}/bin/curl --noproxy '*' --max-time 5 --silent --output response.json --write-out '%{http_code}' \
              --header "Authorization: Bearer $1" http://127.0.0.1:28418/v0/management/config
          }
          accepts() {
            local code
            code="$(request "$1")"
            echo "admin key $1: HTTP $code"
            test "$code" = 200
          }
          refuses() {
            local code
            code="$(request "$1")"
            echo "admin key $1: HTTP $code $(cat response.json)"
            [ "$code" = 401 ] && ${pkgs.jq}/bin/jq -e '.error == "invalid admin key"' response.json > /dev/null
          }
          accepts admin-key-a
          refuses admin-key-wrong
          # Rotate the file and start again on the same state: the stored
          # credential is reset to the new key before the server runs.
          stop
          printf '%s\n' admin-key-b > /build/admin-key
          manager "$main" manager-restart.log
          accepts admin-key-b
          refuses admin-key-a
          # Database and admin-key variables inherited from the user manager's
          # environment are dropped: the next start resets the database the
          # instance declares to the rotated file, and the server opens it.
          stop
          printf '%s\n' admin-key-env-file > /build/env-admin-key
          mkdir -p /build/state/inherited
          export USAGE_DB_PATH=/build/state/inherited/usage.sqlite USAGE_DATA_DIR=/build/state/inherited CPA_MANAGER_ADMIN_KEY=admin-key-env CPA_MANAGER_ADMIN_KEY_FILE=/build/env-admin-key
          printf '%s\n' admin-key-c > /build/admin-key
          manager "$main" manager-inherited.log
          test ! -e /build/state/inherited/usage.sqlite
          accepts admin-key-c
          refuses admin-key-b
          refuses admin-key-env
          refuses admin-key-env-file
          # A declared USAGE_DB_PATH places the database, outside `stateDir`:
          # the first start seeds it, and the next resets it.
          stop
          mkdir -p /build/state/declared-db
          manager "$declared" manager-declared.log
          test -s /build/state/declared-db/usage.sqlite
          test ! -e /build/state/declared/usage.sqlite
          accepts admin-key-c
          theme dark
          stop
          printf '%s\n' admin-key-d > /build/admin-key
          manager "$declared" manager-declared-restart.log
          accepts admin-key-d
          refuses admin-key-c
          # A first start seeds the credential itself; a later one resets it.
          # No key reaches any log. `! grep` would be exempt from errexit, so
          # each absence fails explicitly.
          for log in manager-restart.log manager-inherited.log manager-declared-restart.log; do
            grep -Fx 'CPA Manager Plus admin key reset.' "$log"
          done
          if grep -F 'admin key reset' manager.log manager-declared.log \
            || grep -F -e admin-key-a -e admin-key-b -e admin-key-c -e admin-key-d -e admin-key-env manager*.log; then
            false
          fi
          touch "$out"
        '';
      # The run script's scratch variable for the trimmed admin key never
      # reaches a child process, whatever the environment exports.
      module-service-instances-admin-key = let
        launcher = services.mkLauncher {
          inherit pkgs;
          entry = managed.ai.services.cpa-manager-plus-main;
          name = "cpa-manager-plus-main";
        };
      in
        pkgs.runCommandLocal "module-test-service-instances-admin-key" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s\n' dummy-admin-key > /build/admin-key
          mkdir -p /build/state/managed
          printf '%s' database > /build/state/managed/usage.sqlite
          export XDG_RUNTIME_DIR="$TMPDIR/run" RECEIVED="$TMPDIR/received"
          mkdir -p "$RECEIVED" "$XDG_RUNTIME_DIR"
          # Control for the detection: an exported scratch name does reach a
          # child that nothing clears.
          stripped_key=ambient-leak ${fakeManager}/bin/cpa-manager-plus
          ${pkgs.gnugrep}/bin/grep -Fx 'stripped_key=ambient-leak' "$RECEIVED/daemon.env"
          rm "$RECEIVED"/*
          # When the same exported name is set to the key, neither the name
          # nor the value can reach the reset or the daemon.
          stripped_key=dummy-admin-key ${launcher}/bin/ai-service-cpa-manager-plus-main
          for call in reset-admin-key daemon; do
            test -s "$RECEIVED/$call.env"
            if ${pkgs.gnugrep}/bin/grep -F -e stripped_key -e dummy-admin-key -e ambient-leak "$RECEIVED/$call.env"; then
              echo "the admin key reached the $call environment" >&2
              exit 1
            fi
          done
          touch "$out"
        '';
      # A configured key outside the allowlist and an unknown key are refused.
      module-service-instances-key-allowlist = let
        upstream = {
          name = "alpha";
          base-url = "http://127.0.0.1:28420/v1";
          keys = [{api-key = upstreamKey "alpha";}];
          models = [{name = "shared-model";}];
        };
      in
        keyAllowlistCheck {
          ai.cliproxyapi.instances.main.settings = {
            access = {
              api-keys = map fileKey ["a" "other"];
              key-allowlist = [(allow "a" {provider = "openai-compatible-alpha";})];
            };
            api-keys.openai-compatibility = [upstream];
          };
          name = "key-allowlist";
          port = 28419;
          requests = ''
            request 200 alpha chat shared-model key-a
            request 503 auth_not_found chat shared-model key-other
            request 401 "Invalid API key" chat shared-model key-unknown
          '';
          upstreams = ["alpha:28420:/v1/chat/completions"];
        };
      # Two access.key-allowlist entries whose keys are different redact.file
      # references, so evaluation cannot compare them, resolve at start to one
      # key once trimmed. Merged, that key would hold both entries' rules; the
      # packaged CPA refuses the config instead, naming the entries by index and
      # never the key, and the patch makes main exit with a non-zero status
      # before serving (packages/cliproxyapi/docs/cliproxyapi-key-allowlist.md).
      # Positive control: a second instance with distinct keys, started the same
      # way, comes up and keeps running, so the exit comes from the refusal.
      module-service-instances-key-allowlist-duplicate = let
        instance = port: names:
          daemonInstance port names {
            access.key-allowlist = lib.zipListsWith (name: provider: allow name {inherit provider;}) names ["claude" "codex"];
          };
        proxy =
          (evalHm {
            ai.cliproxyapi.instances = {
              duplicate = instance 28424 ["a" "twin"];
              valid = instance 28425 ["ok-a" "ok-b"];
            };
          }).config;
        exec = name: proxy.systemd.user.services."cliproxyapi-${name}".Service.ExecStart;
      in
        pkgs.runCommandLocal "module-test-service-instances-key-allowlist-duplicate" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s' key-same > /build/key-a
          printf ' %s\n' key-same > /build/key-twin
          printf '%s' key-ok-a > /build/key-ok-a
          printf '%s' key-ok-b > /build/key-ok-b
          ${daemonHarness "key-allowlist-duplicate"}
          ${exec "valid"} > valid.log 2>&1 &
          processes+=("$!")
          ready "$!" http://127.0.0.1:28425/healthz valid.log
          status=0
          timeout --kill-after=5 30 ${exec "duplicate"} > cpa.log 2>&1 || status=$?
          cat cpa.log
          # 124 and 137 are timeout's own: CPA was still running after 30 s.
          case $status in
            0 | 124 | 137)
              echo "FAIL: CPA with two entries for one client key gave status $status, want its own non-zero exit" >&2
              false
              ;;
          esac
          echo "ok: the refused config exited with status $status"
          grep -F 'failed to load config: access.key-allowlist: entries 0, 1 have the same api-key after trimming' cpa.log
          if grep -F key-same cpa.log; then
            echo "FAIL: the refusal printed the client key" >&2
            false
          fi
          ready "''${processes[0]}" http://127.0.0.1:28425/healthz valid.log
          echo "ok: the valid config still runs"
          touch "$out"
        '';
      # Each runtime's generated key reaches its named provider on its API.
      module-service-instances-runtime-providers = let
        provider = name: port: {
          apis = {
            anthropic.base-url = claudeBaseURL port;
            responses.base-url = "${claudeBaseURL port}/v1";
          };
          key = upstreamKey name;
          models = ["glm-shared" "${name}-model"];
        };
        runtime = name: {
          instance = "main";
          clientKey = name;
        };
      in
        keyAllowlistCheck {
          ai = {
            claude = {
              enable = true;
              settings.inference = runtime "a";
            };
            cliproxyapi.instances.main = {
              credentials = {
                other.apiKey = provider "other" 28428 // {apis.chat.base-url = "${claudeBaseURL 28428}/v1";};
                zhipuai.apiKey = provider "zhipuai" 28427;
              };
              clientKeys = {
                a = {
                  key = fileKey "a";
                  routes = [
                    {
                      credential = "zhipuai";
                      api = "anthropic";
                    }
                  ];
                };
                b = {
                  key = fileKey "b";
                  routes = [
                    {
                      credential = "other";
                      api = "chat";
                    }
                  ];
                };
              };
            };
            codex = {
              enable = true;
              settings.inference = runtime "b";
            };
          };
          name = "runtime-providers";
          port = 28426;
          requests = ''
            request 200 zhipuai anthropic glm-shared key-a
            request 200 other responses glm-shared key-b
            request 503 auth_not_found anthropic other-model key-a
            request 503 auth_not_found responses zhipuai-model key-b
            echo "ok: Codex CLI Responses reached chat-only upstream credential; unauthorized model refused"
          '';
          upstreams = ["zhipuai:28427:/v1/messages?beta=true" "other:28428:/v1/chat/completions"];
          verify = config: ''
            test "$(${pkgs.bash}/bin/bash -c ${lib.escapeShellArg (claudeSettings {inherit config;}).apiKeyHelper})" = key-a
            test "$(${config.ai.codex.files.".codex/config.toml".content.value.model_providers.ai-inference.auth.command})" = key-b
            echo "ok: Claude's key helper resolves key-a, Codex's key-b"
          '';
        };
      # Linux Home Manager emits the units, and the launcher renders the
      # config the run script hands to CLIProxyAPI from inside its state.
      module-service-instances-run = let
        launcherFor = config:
          services.mkLauncher {
            inherit pkgs;
            entry = config.ai.services.cliproxyapi-main;
            name = "cliproxyapi-main";
          };
        launcher = launcherFor runnable;
        launcherOn = launcherFor phoneHomeOn;
      in
        assert lib.assertMsg (
          lib.all (name: lib.hasSuffix "/bin/ai-service-${name}" hm.systemd.user.services.${name}.Service.ExecStart) ["cliproxyapi-main" "cpa-manager-plus-main"]
          && !(disabled.systemd.user.services ? cliproxyapi-main)
          && standalone.systemd.user.services.cpa-manager-plus-main.Unit.Wants == ["sops-nix.service"]
          && standalone.systemd.user.services.cpa-manager-plus-main.Unit.After == ["network.target" "sops-nix.service"]
          && !(disabled.systemd.user.services.cpa-manager-plus-main.Unit ? Wants)
          && disabled.systemd.user.services.cpa-manager-plus-main.Unit.After == ["network.target"]
        ) "module-service-instances-run: Home Manager units";
          pkgs.runCommandLocal "module-test-service-instances-run" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            printf '%s' client-secret > /build/client-key
            printf '%s' management-secret > /build/management-key
            export XDG_RUNTIME_DIR="$TMPDIR/run" RECEIVED="$TMPDIR/received"
            mkdir -p "$RECEIVED" "$XDG_RUNTIME_DIR"
            ${launcher}/bin/ai-service-cliproxyapi-main
            # Off by default: embedded catalogs and no panel updater.
            printf '%s\n' "--config $XDG_RUNTIME_DIR/ai-service-cliproxyapi-main/config.json --local-model" /build/state/main > expected
            ${pkgs.diffutils}/bin/diff -u expected "$RECEIVED/argv"
            test "$(${pkgs.coreutils}/bin/tr '\n' ' ' < "$RECEIVED/modes")" = '700 700 '
            ${pkgs.jq}/bin/jq -e '.access."api-keys" == ["client-secret"] and .management."secret-key" == "management-secret" and .management."disable-auto-update-panel" == true and .oauth."auth-dir" == "/build/state/main/auth"' "$RECEIVED/config.json"
            # A consumer override turns both back on.
            export RECEIVED="$TMPDIR/received-on" XDG_RUNTIME_DIR="$TMPDIR/run-on"
            mkdir -p "$RECEIVED" "$XDG_RUNTIME_DIR"
            ${launcherOn}/bin/ai-service-cliproxyapi-main
            printf '%s\n' "--config $XDG_RUNTIME_DIR/ai-service-cliproxyapi-main/config.json" /build/state/main > expected-on
            ${pkgs.diffutils}/bin/diff -u expected-on "$RECEIVED/argv"
            ${pkgs.jq}/bin/jq -e '.management."disable-auto-update-panel" == false' "$RECEIVED/config.json"
            touch "$out"
          '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Fails when an instance's service is missing from launchd or runs something other than its launcher.
      module-service-instances-darwin-launchd = mkTest "service-instances-darwin-launchd" (
        hm.systemd.user.services
        == {}
        && lib.all (launchdAgentRunsLauncher hm) ["cliproxyapi-main" "cpa-manager-plus-main"]
      );
    };
}
