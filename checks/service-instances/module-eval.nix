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
  inherit (harness) evalDevenv evalHm mkTest;
  redact = import ../../lib/redact {inherit lib;};
  services = import ../../packages/ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../lib/strict-shell-application.nix;

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
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);

  # The service entries and claims both backends share.
  entries = backend: let
    inherit (evaluate backend (withInstances {})) config;
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
    && builtins.fromJSON proxy.files.config.content
    == {
      access.api-keys = [(placeholder "CLIPROXYAPI_ACCESS_API_KEYS_0")];
      management = {
        # The panel is not downloaded unprompted unless a consumer asks.
        disable-auto-update-panel = true;
        secret-key = placeholder "CLIPROXYAPI_MANAGEMENT_SECRET_KEY";
      };
      oauth.auth-dir = "${root}/cliproxyapi/main/auth";
      server = {
        host = "127.0.0.1";
        port = 8400;
      };
    }
    && (evaluate backend (withInstances {cliproxyapi.instances.main.settings.server.host = "192.0.2.1";})).config.ai.cliproxyapi.instances.main.settings.server.host == "192.0.2.1"
    && !config.ai.cliproxyapi.instances.main.fetchModelCatalogs
    && builtins.fromJSON (evaluate backend (withInstances {cliproxyapi.instances.main.settings.management.disable-auto-update-panel = false;})).config.ai.services.cliproxyapi-main.files.config.content
    == {
      access.api-keys = [(placeholder "CLIPROXYAPI_ACCESS_API_KEYS_0")];
      management = {
        disable-auto-update-panel = false;
        secret-key = placeholder "CLIPROXYAPI_MANAGEMENT_SECRET_KEY";
      };
      oauth.auth-dir = "${root}/cliproxyapi/main/auth";
      server = {
        host = "127.0.0.1";
        port = 8400;
      };
    }
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
    && failures (evaluate backend (withInstances {})) == [];

  # CLIProxyAPI settings on the main instance, by case name: the settings and
  # what evaluating them gives, `thrown` when an option type or the render
  # refuses them, else the failed assertions.
  settingsCases = let
    accepted = settings: {
      inherit settings;
      expect = [];
    };
    fails = message: settings: {
      inherit settings;
      expect = [message];
    };
    thrown = settings: {
      inherit settings;
      expect = "thrown";
    };
    # One client key with one rule: a valid API-key rule, then `rule` on top.
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
    emptied = field: fails "ai.cliproxyapi.instances.main: settings.access.key-allowlist[].credentials[].${field} merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value." (allowing {${field} = [(lib.mkIf false "x")];});
    nullEntry = fails "ai.cliproxyapi.instances.main: settings.access.key-allowlist has a null entry, which the renderer drops: a list of only nulls renders as [] and switches enforcement off for every key. Remove the null entry, or set the list to [] to switch the allowlist off.";
    oauth.kind = "oauth";
    urls = ["https://api.z.ai/api/anthropic"];
  in {
    # Accepted, and rendered.
    "allowlist switched off" = accepted {access.key-allowlist = [];};
    "apikey rule narrowed by base-urls and ids" = accepted (allowing {
      base-urls = urls;
      ids = ["claude-apikey"];
    });
    "mkIf lists that keep an element" = accepted (allowing {
      base-urls = [(lib.mkIf true "x") (lib.mkIf false "y")];
      ids = [(lib.mkIf true "x") (lib.mkIf false "y")];
    });
    "oauth rule narrowed by ids" = accepted (allowing (oauth // {ids = ["claude-oauth"];}));
    "plugins without an allowlist" = accepted {plugins.enabled = true;};

    # Refused by an assertion. The types check definitions, so a list of only
    # `mkIf false` elements passes them and merges to [], which CPA reads as
    # unrestricted; the assertion on the merged value refuses it, per field.
    "base-urls emptied by mkIf" = emptied "base-urls";
    "ids emptied by mkIf" = emptied "ids";
    "null allowlist entry" = nullEntry {access.key-allowlist = [null];};
    "null allowlist entry beside a rule" = nullEntry {access.key-allowlist = [null] ++ (allowing {}).access.key-allowlist;};
    "oauth rule with base-urls" = fails "ai.cliproxyapi.instances.main: settings.access.key-allowlist has a rule with kind = \"oauth\" and base-urls, which can never match: base-urls compare an API-key credential's base URL and never match an OAuth login. Use kind = \"apikey\" or drop base-urls." (allowing (oauth // {base-urls = urls;}));
    # Its one failure also proves a bare rule, with no ids or base-urls, passes.
    "plugins beside the allowlist" = fails "ai.cliproxyapi.instances.main: settings.plugins.enabled = true voids settings.access.key-allowlist: plugin executors choose credentials outside it and can read every credential through host.auth.get. Disable plugins or drop the allowlist." (allowing oauth // {plugins.enabled = true;});

    # Refused at evaluation.
    "empty base-urls" = thrown (allowing {base-urls = [];});
    "empty ids" = thrown (allowing {ids = [];});
    "null base-urls element" = thrown (allowing {base-urls = [null];});
    "null ids element" = thrown (allowing {ids = [null];});
    "plaintext client key" = thrown {access.api-keys = ["plain-client-key"];};
    "port other than the instance's" = thrown {server.port = 9999;};
    "unknown kind" = thrown (allowing {kind = "wrong";});
  };

  # Every settings case, an upstream that names no enabled instance, and each
  # Manager Plus admin key and path refusal.
  refusals = backend: let
    outcome = settings: let
      result = evaluate backend (withInstances {cliproxyapi.instances.main.settings = settings;});
    in
      if succeeds result.config.ai.services.cliproxyapi-main.files
      then failures result
      else "thrown";
  in
    settingsCases
    != {}
    && lib.all lib.id (lib.mapAttrsToList (name: case: outcome case.settings == case.expect || builtins.trace "${backend}: settings case `${name}` failed" false) settingsCases)
    && failures (evaluate backend (withInstances {cpa-manager-plus.instances.main.upstream = "missing";}))
    == ["ai.cpa-manager-plus.instances.main.upstream names `missing`, which is not an `ai.cliproxyapi.instances` entry."]
    && failures (evaluate backend (withInstances {cliproxyapi.instances.main.enable = false;}))
    == ["ai.cpa-manager-plus.instances.main.upstream names `ai.cliproxyapi.instances.main`, which is disabled."]
    # Each other admin key form is steered to adminKeyFile, never ignored.
    && failures (evaluate backend (withInstances {
      cpa-manager-plus.instances.main.settings = {
        config.adminKeyFile = "admin.key";
        environment = {
          CPA_MANAGER_ADMIN_KEY = redact.file "/run/secrets/cpa-admin-key";
          CPA_MANAGER_ADMIN_KEY_FILE = "/run/secrets/cpa-admin-key";
        };
      };
    }))
    == [
      "ai.cpa-manager-plus.instances.main.settings.environment.CPA_MANAGER_ADMIN_KEY: set settings.config.adminKeyFile instead; Manager Plus reads CPA_MANAGER_ADMIN_KEY only on its first start, while the instance applies adminKeyFile on every start."
      "ai.cpa-manager-plus.instances.main.settings.environment.CPA_MANAGER_ADMIN_KEY_FILE: set settings.config.adminKeyFile instead; Manager Plus reads CPA_MANAGER_ADMIN_KEY_FILE only on its first start, while the instance applies adminKeyFile on every start."
      "ai.cpa-manager-plus.instances.main.settings.config.adminKeyFile: must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, not `admin.key`."
    ]
    # Bootstrap trims the path it reads; a trailing space would name another file.
    && failures (evaluate backend (withInstances {cpa-manager-plus.instances.main.settings.config.adminKeyFile = "/run/secrets/cpa-admin-key ";}))
    == ["ai.cpa-manager-plus.instances.main.settings.config.adminKeyFile: must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, not `/run/secrets/cpa-admin-key `."]
    # With adminKeyFile, every input that places the database must be a path
    # Manager Plus opens as written; without it, none is refused.
    && failures (evaluate backend (withInstances {
      cpa-manager-plus.instances.main = {
        settings = unclean // {config = unclean.config // {adminKeyFile = "/run/secrets/cpa-admin-key";};};
        stateDir = "/srv/state/../manager";
      };
    }))
    == map (option: "ai.cpa-manager-plus.instances.main.${option}: with settings.config.adminKeyFile set, must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, which Manager Plus opens as written; not `${lib.attrByPath (lib.tail (lib.splitString "." option)) "/srv/state/../manager" unclean}`.") [
      "settings.config.dataDir"
      "settings.config.dbPath"
      "settings.environment.USAGE_DATA_DIR"
      "settings.environment.USAGE_DB_PATH"
    ]
    && failures (evaluate backend (withInstances {cpa-manager-plus.instances.main.settings = unclean;})) == [];
  unclean = {
    config.dbPath = "missing/../usage.sqlite";
    environment = {
      USAGE_DATA_DIR = "/srv/manager/";
      USAGE_DB_PATH = "/srv/manager/usage.sqlite${builtins.fromJSON ''"\u00a0"''}";
    };
  };

  # adminKeyFile restarts the instance when its bytes change.
  keyed = backend:
    services.triggers (evaluate backend (withInstances {cpa-manager-plus.instances.main.settings.config.adminKeyFile = "/run/secrets/cpa-admin-key";})).config.ai.services.cpa-manager-plus-main
    == ["/run/secrets/cpa-admin-key" "/run/secrets/cpa-management-key"];

  # adminKeyFile alone, with no upstream management key, still waits for the
  # secret providers; `disabled` has neither and stays a plain unit.
  standalone =
    (evalHm (withInstances {
      cpa-manager-plus.instances.main = {
        settings.config.adminKeyFile = "/run/secrets/cpa-admin-key";
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
        lib.all (backend: entries backend && keyed backend && refusals backend) ["devenv" "hm"]
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
                settings.config.adminKeyFile = "/build/admin-key";
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
              adminKeyFile = "/build/admin-key";
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
          # A first start refuses a key file that is blank to strings.TrimSpace,
          # here a lone no-break space, before bootstrap could generate and log a key.
          printf '\302\240\n' > /build/admin-key
          if "$main" > blank.log 2>&1; then
            echo "a blank admin key file started Manager Plus" >&2
            exit 1
          fi
          ${pkgs.gnugrep}/bin/grep -F 'is unreadable or blank' blank.log
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
          # Manager Plus answers 401 "invalid admin key" for any other key.
          request() {
            ${pkgs.curl}/bin/curl --noproxy '*' --max-time 5 --silent --output response.json --write-out '%{http_code}' \
              --header "Authorization: Bearer $1" http://127.0.0.1:28418/v0/management/config
          }
          accepts() {
            local code
            code="$(request "$1")"
            echo "admin key $1: HTTP $code"
            [ "$code" != 401 ] && [ "$code" != 500 ]
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
      # access.key-allowlist (packages/cliproxyapi/patches/key-allowlist.patch)
      # in the packaged CPA, against stand-in upstreams. Two client keys are
      # each allowed one of two openai-compatibility providers that serve a
      # shared model. Two more are each allowed one of two api-keys.claude
      # groups, one provider on one protocol, told apart only by base-urls.
      # Each key reaches only its own upstream, a request for another's model
      # and a listed key with no entry select no credential, and an unknown key
      # is refused at authentication. One request per query form shows the
      # packaged server holds it to the key's entry; the access package's Go
      # test covers the rest of that matrix through the real middleware.
      module-service-instances-key-allowlist = let
        upstream = name: port: {
          inherit name;
          base-url = "http://127.0.0.1:${toString port}/v1";
          keys = [{api-key = redact.file "/build/upstream-${name}";}];
          models = [{name = "shared-model";} {name = "${name}-model";}];
        };
        # The claude executor appends /v1/messages to the base URL itself.
        claudeBaseURL = port: "http://127.0.0.1:${toString port}";
        claude = name: port: {
          inherit name;
          base-url = claudeBaseURL port;
          keys = [{api-key = redact.file "/build/upstream-${name}";}];
          models = [{name = "claude-shared";}];
        };
        proxy =
          (evalHm {
            ai.cliproxyapi.instances.main = {
              package = cliproxyapi;
              port = 28419;
              settings = {
                access = {
                  api-keys = map fileKey ["a" "b" "other" "unlisted" "zai"];
                  key-allowlist = [
                    (allow "a" {provider = "openai-compatible-alpha";})
                    (allow "b" {provider = "openai-compatible-beta";})
                    (allow "zai" {
                      provider = "claude";
                      base-urls = [(claudeBaseURL 28422)];
                    })
                    (allow "other" {
                      provider = "claude";
                      base-urls = [(claudeBaseURL 28423)];
                    })
                  ];
                };
                api-keys = {
                  claude = [(claude "zai" 28422) (claude "other" 28423)];
                  openai-compatibility = [(upstream "alpha" 28420) (upstream "beta" 28421)];
                };
              };
              stateDir = "/build/state/cpa";
            };
          }).config;
      in
        pkgs.runCommandLocal "module-test-service-instances-key-allowlist" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          for name in a b other unlisted zai; do printf '%s' "key-$name" > "/build/key-$name"; done
          for name in alpha beta other zai; do printf '%s' "upstream-$name" > "/build/upstream-$name"; done
          ${daemonHarness "key-allowlist"}
          for upstream in alpha:28420 beta:28421 zai:28422 other:28423; do
            name=''${upstream%:*} port=''${upstream#*:}
            ${pkgs.python3}/bin/python3 ${./stand-in-upstream.py} "$name" "$port" "$name.log" 2> "$name.err" &
            processes+=("$!")
            ready "$!" "http://127.0.0.1:$port/" "$name.err"
          done
          ${proxy.systemd.user.services.cliproxyapi-main.Service.ExecStart} > cpa.log 2>&1 &
          processes+=("$!")
          ready "$!" http://127.0.0.1:28419/healthz cpa.log
          # request <status> <answer> <model> <query> [<client key header>]:
          # an OpenAI chat completion for model, or an Anthropic message when
          # model is claude-shared. A 200 answers with the upstream's name, a
          # refusal carries its error.
          request() {
            local status=$1 answer=$2 model=$3 query=$4 key=''${5:-} code path=/v1/chat/completions extra=""
            if [ "$model" = claude-shared ]; then path=/v1/messages extra=',"max_tokens":16'; fi
            local args=(--noproxy '*' --max-time 10 --silent --output response.json --write-out '%{http_code}' --header 'Content-Type: application/json')
            if [ -n "$key" ]; then args+=(--header "Authorization: Bearer $key"); fi
            code=$(${pkgs.curl}/bin/curl "''${args[@]}" --data "{\"model\":\"$model\"$extra,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" "http://127.0.0.1:28419$path$query")
            if [ "$code" != "$status" ] || ! ${pkgs.jq}/bin/jq -e --arg answer "$answer" '(.choices[0].message.content? // .content[0].text? // .error.message? // .error? // "") | contains($answer)' response.json > /dev/null 2>&1; then
              echo "FAIL: header ''${key:-none}, query '$query', $model: $code, want $status $answer" >&2
              cat response.json cpa.log >&2
              return 1
            fi
            echo "ok: header ''${key:-none}, query '$query', $model: $code $answer"
          }
          # Consecutive requests per key: a rotation over both upstreams of a
          # model would hand the second one to the other upstream.
          for key in a:alpha b:beta; do
            for round in 1 2 3; do request 200 "''${key#*:}" shared-model "" "key-''${key%:*}"; done
          done
          for key in zai other; do
            for round in 1 2 3; do request 200 "$key" claude-shared "" "key-$key"; done
          done
          request 200 alpha alpha-model "" key-a
          request 503 auth_not_found claude-shared "" key-a
          request 503 auth_not_found beta-model "" key-a
          request 503 auth_not_found shared-model "" key-unlisted
          request 401 "Invalid API key" shared-model "" key-unknown
          request 503 auth_not_found beta-model "?key=key-a"
          request 200 beta shared-model "?auth_token=key-b"
          # Every upstream call carried that upstream's own credential, as many
          # as the 200s above that name it.
          for upstream in alpha:4:/v1/chat/completions beta:4:/v1/chat/completions "zai:3:/v1/messages?beta=true" "other:3:/v1/messages?beta=true"; do
            IFS=: read -r name calls path <<< "$upstream"
            test "$(sort -u "$name.log")" = "$path Bearer upstream-$name"
            test "$(wc -l < "$name.log")" -eq "$calls"
            echo "ok: $name received $calls calls, all with its own credential"
          done
          touch "$out"
        '';
      # Two access.key-allowlist entries whose keys are different redact.file
      # references, so evaluation cannot compare them, resolve at start to one
      # key once trimmed. Merged, that key would hold both entries' rules; the
      # packaged CPA refuses the config instead, naming the entries by index and
      # never the key, and the patch makes main exit with a non-zero status
      # before serving (packages/cliproxyapi/docs/cliproxyapi-key-allowlist.md).
      # Positive control: a second instance with distinct keys, started the same
      # way, comes up and keeps running, so the exit comes from the refusal.
      module-service-instances-key-allowlist-duplicate = let
        instance = port: names: {
          package = cliproxyapi;
          inherit port;
          settings.access = {
            api-keys = map fileKey names;
            key-allowlist = lib.zipListsWith (name: provider: allow name {inherit provider;}) names ["claude" "codex"];
          };
          stateDir = "/build/state/${toString port}";
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
          if ! kill -0 "''${processes[0]}" 2>/dev/null; then
            cat valid.log >&2
            echo "FAIL: the valid config did not keep running" >&2
            false
          fi
          echo "ok: the valid config still runs"
          touch "$out"
        '';
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
      module-service-instances-darwin-warns = mkTest "service-instances-darwin-warns" (
        hm.systemd.user.services
        == {}
        && lib.all (name: lib.elem "ai.services.${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written" hm.warnings) ["cliproxyapi-main" "cpa-manager-plus-main"]
      );
    };
}
