# Refuse lost aliases/envelopes, secret URLs rendered as objects, shared-URL
# over-grants and passthrough credentials published to inference consumers.
{
  extractedLib,
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) fill;
  redact = import ../../../lib/redact {inherit lib;};
  secret = name: redact.file "/run/secrets/${name}";
  path = redact.concat ["/accounts/" (secret "account") "/decision"];
  base = redact.concat ["https://" (secret "host")];
  upstream = {
    apis.passthrough = {
      base-url = base;
      error-in-200 = {
        equals = false;
        path = "success";
        status = 429;
      };
      models = [
        {
          alias = "decision";
          name = "upstream-model";
        }
      ];
      inherit path;
      unwrap = "result";
      usage-path = "result.usage";
    };
    key = secret "upstream";
    priority = 30;
  };
  fixture = {
    clientKeys.main = {
      key = secret "client";
      routes = [{credential = "Free";} {credential = "paid";} {credential = "chat";}];
    };
    credentials = {
      Free.apiKey = upstream;
      chat.apiKey = {
        apis.chat.base-url = "https://chat.example/v1";
        key = secret "chat";
        models = ["chat-model"];
      };
      paid.apiKey = lib.recursiveUpdate upstream {priority = 20;};
    };
    enable = true;
    settings.config-version = 8;
  };
  evaluate = backend: change:
    backend {
      ai = {
        claude = {
          enable = true;
          settings.inference = {
            instance = "main";
            clientKey = "main";
          };
        };
        cliproxyapi.instances.main = lib.recursiveUpdate fixture change;
      };
    };
  backends = {
    devenv = harness.evalDevenv;
    hm = harness.evalHm;
  };
  failures = result: map (entry: entry.message) (lib.filter (entry: !entry.assertion) result.config.assertions);
  refuses = backend: change: let
    result = evaluate backend change;
    value = {inherit (result.config.ai.cliproxyapi.instances.main) credentials settings;};
    attempt = builtins.tryEval (builtins.deepSeq value (failures result == []));
  in
    !attempt.success || !attempt.value;
  expectedBlock = {
    base-url = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_BASE_URL}";
    error-in-200 = {
      equals = false;
      path = "success";
      status = 429;
    };
    keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_KEYS_0_API_KEY}";}];
    models = [
      {
        alias = "decision";
        name = "upstream-model";
      }
    ];
    name = "Free";
    path = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_PATH}";
    priority = 30;
    unwrap = "result";
    usage-path = "result.usage";
  };
  expectedRules = [
    {
      base-urls = ["{$CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_CREDENTIALS_0_BASE_URLS_0}"];
      kind = "apikey";
      provider = "passthrough-free";
    }
    {
      base-urls = ["{$CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_CREDENTIALS_1_BASE_URLS_0}"];
      kind = "apikey";
      provider = "passthrough-paid";
    }
    {
      base-urls = ["https://chat.example/v1"];
      kind = "apikey";
      provider = "openai-compatible-chat";
    }
  ];
  # Native loader receives only synthetic values, through the shared fill engine.
  rendered = cliproxyapi.render (evaluate harness.evalHm {}).config.ai.cliproxyapi.instances.main.settings;
  values = lib.mapAttrs (_: reference:
    if reference == base
    then "https://upstream.example"
    else if reference == path
    then "/accounts/synthetic-account/decision"
    else "synthetic-key")
  rendered.secrets;
  nativeConfig = fill values rendered.content;
  invalid = {
    absolute-path.credentials.Free.apiKey.apis.passthrough.path = "https://elsewhere.example/path";
    empty-models.credentials.Free.apiKey.apis.passthrough.models = [];
    malformed-model-alias.credentials.Free.apiKey.apis.passthrough.models = [
      {
        name = "upstream-model";
        alias = 1;
      }
    ];
    missing-model-name.credentials.Free.apiKey.apis.passthrough.models = [{alias = "decision";}];
    missing-models.credentials.Free.apiKey.apis.passthrough = lib.mkForce {
      base-url = "https://upstream.example";
      path = "/decision";
    };
    network-path.credentials.Free.apiKey.apis.passthrough.path = "//elsewhere.example/path";
    null-models.credentials.Free.apiKey.apis.passthrough.models = null;
    string-models.credentials.Free.apiKey.apis.passthrough.models = ["upstream-model"];
    unknown-api.credentials.Free.apiKey.apis.unknown.base-url = "https://upstream.example";
  };
  moduleChecks = lib.mapAttrs (backendName: backend:
    harness.mkTest "passthrough-module-${backendName}" (let
      result = evaluate backend {};
      settings = builtins.fromJSON (cliproxyapi.render result.config.ai.cliproxyapi.instances.main.settings).content;
      narrowed = field: entries: {
        settings.access.key-allowlist = [
          {
            api-key = secret "raw-client";
            credentials = [
              {
                provider = "passthrough-free";
                kind = "apikey";
                ${field} = entries;
              }
            ];
          }
        ];
      };
      direct =
        cliproxyapi.render
        (evaluate backend {
          credentials = lib.mkForce {};
          clientKeys = lib.mkForce {};
          settings = {
            api-keys.passthrough = [
              (raw "direct"
                // {
                  base-url = base;
                  inherit path;
                })
            ];
            access.key-allowlist = [
              {
                api-key = secret "direct-client";
                credentials = [
                  {
                    provider = "passthrough-direct";
                    kind = "apikey";
                    base-urls = [base];
                  }
                ];
              }
            ];
          };
        }).config.ai.cliproxyapi.instances.main.settings;
      raw = name: {
        inherit name;
        base-url = "https://upstream.example";
        path = "/decision";
        models = [{name = "upstream-model";}];
        keys = [{api-key = secret "raw";}];
      };
      # Check the specific assertion, rather than accepting an unrelated
      # failure: Unicode group names otherwise pass Nix and fail CPA startup.
      rawNameRefused = name:
        lib.any (lib.hasSuffix "].name: group names must contain only printable ASCII characters so Nix and CPA normalize them identically.")
        (failures (evaluate backend {settings.api-keys.passthrough = [(raw name)];}));
      cases =
        {
          "allowlist empty URL restriction refused" = refuses backend (narrowed "base-urls" []);
          "allowlist null URL refused" = refuses backend (narrowed "base-urls" [null]);
          "allowlist URL restriction emptied by mkIf refused" = refuses backend (narrowed "base-urls" [(lib.mkIf false "https://upstream.example")]);
          "client access retained" = settings.access.api-keys == ["{$CLIPROXYAPI_ACCESS_API_KEYS_0}"];
          "concat path reference renders with shared engine" = rendered.secrets.CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_PATH == path;
          "direct typed settings accept URL and allowlist references" =
            direct.secrets.CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_BASE_URL
            == base
            && direct.secrets.CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_PATH == path
            && direct.secrets.CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_CREDENTIALS_0_BASE_URLS_0 == base;
          "existing prefix is always prefixed" = cliproxyapi.providers.apis.passthrough.provider "Passthrough-Free" == "passthrough-passthrough-free";
          "harness fanout excludes passthrough" =
            result.config.ai.claude.normalized.settings.inference.credentials
            == [
              {
                name = "chat";
                models = ["chat-model"];
              }
            ];
          "literal config preserves alias, priority and envelopes" = lib.head settings.api-keys.passthrough == expectedBlock;
          "literal rules retain distinct named identities at a shared URL" = (lib.head settings.access.key-allowlist).credentials == expectedRules;
          "mixed raw duplicate refused after ASCII case and space normalization" =
            failures (evaluate backend {settings.api-keys.passthrough = [(raw " fReE ")];})
            == ["ai.cliproxyapi.instances.main.settings.api-keys.passthrough: duplicate group names after trimming and lowercase normalization, including named credentials and raw blocks."];
          "models emptied by mkIf refused" = refuses backend {credentials.Free.apiKey.apis.passthrough.models = [(lib.mkIf false {name = "upstream-model";})];};
          "named base reference renders with shared engine" = rendered.secrets.CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_BASE_URL == base;
          "named duplicate refused" = refuses backend {credentials.free.apiKey = upstream;};
          "passthrough routes excluded from inference" =
            result.config.ai.internal.inferenceInstances.main.clients.main
            == {
              key = secret "client";
              credentials = [
                {
                  name = "chat";
                  models = ["chat-model"];
                }
              ];
            };
          "raw name with form feed refused" = rawNameRefused (builtins.fromJSON ''"free\f"'');
          "raw name with non-ASCII letter refused" = rawNameRefused "Ä";
          "raw name with non-breaking space refused" = rawNameRefused (builtins.fromJSON ''"\u00a0free\u00a0"'');
          "raw name with vertical tab refused" = rawNameRefused (builtins.fromJSON ''"\u000b"'' + "free");
          "raw settings reject absolute path" = refuses backend {settings.api-keys.passthrough = [(raw "other" // {path = "https://elsewhere.example/path";})];};
          "raw settings reject network path" = refuses backend {settings.api-keys.passthrough = [(raw "other" // {path = "//elsewhere.example/path";})];};
          "rooted and relative paths accepted" = lib.all (path: failures (evaluate backend {credentials.Free.apiKey.apis.passthrough = {inherit path;};}) == []) ["/inference/v1/decision" "inference/v1/decision"];
          "shared URLs accepted" = failures result == [];
          "substitution fills concat URL and allowlist URL" = let
            filled = builtins.fromJSON nativeConfig;
          in
            (lib.head filled.api-keys.passthrough).path
            == "/accounts/synthetic-account/decision"
            && (lib.head (lib.head filled.access.key-allowlist).credentials).base-urls == ["https://upstream.example"];
        }
        // lib.mapAttrs (_: change: refuses backend change) invalid;
      problems = builtins.attrNames (lib.filterAttrs (_: holds: !holds) cases);
    in
      lib.assertMsg (problems == []) "${backendName}: ${lib.concatStringsSep "; " problems}"))
  backends;
  # Reuse every existing provider regression rather than duplicate its fixtures.
  regressions = (import ../../../checks/ai-inference/module-eval.nix {inherit harness lib pkgs;}).checks;
  # The real shared reader resolves concat parts at runtime, without reading
  # a secret during evaluation. This command emits synthetic fixture material.
  accountCommand = import ../../../lib/strict-shell-application.nix pkgs {
    name = "passthrough-synthetic-account";
    text = "printf '%s' synthetic-account";
  };
  concatReference = redact.concat ["/accounts/" (redact.command (lib.getExe accountCommand)) "/decision"];
  secrets = pkgs.runCommand "passthrough-concat-reader" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${redact.assign {
      inherit pkgs;
      option = "passthrough.path";
      variable = "PASSTHROUGH_PATH";
      value = concatReference;
    }}
    test "$PASSTHROUGH_PATH" = /accounts/synthetic-account/decision
    echo "shared reader resolved concat path" > "$out"
  '';
  native = (extractedLib {inherit pkgs;}).goTest {
    name = "cliproxyapi-passthrough-module-native";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
    packagePath = "internal/config";
    run = "TestNatPassthroughModule";
    sources = {
      "nat_passthrough.json" = pkgs.writeText "passthrough-module.json" nativeConfig;
      "nat_passthrough_test.go" = pkgs.writeText "passthrough-module-test.go" ''
        package config
        import (
          "os"
          "testing"
        )
        func TestNatPassthroughModule(t *testing.T) {
          data, err := os.ReadFile("nat_passthrough.json")
          if err != nil { t.Fatal(err) }
          if err := ValidateV8Config(data); err != nil { t.Fatal(err) }
          cfg, err := ParseConfigBytes(data)
          if err != nil { t.Fatal(err) }
          if len(cfg.Passthrough) != 2 { t.Fatal("lost passthrough groups") }
          g := cfg.Passthrough[0]
          if g.ProviderKey() != "passthrough-free" || g.Priority != 30 ||
             g.BaseURL != "https://upstream.example" || g.Path != "/accounts/synthetic-account/decision" ||
             len(g.Models) != 1 || g.Models[0].Alias != "decision" || g.Models[0].Name != "upstream-model" ||
             g.Unwrap == nil || *g.Unwrap != "result" || g.UsagePath == nil || *g.UsagePath != "result.usage" ||
             g.ErrorIn200 == nil || g.ErrorIn200.Equals == nil || *g.ErrorIn200.Equals || g.ErrorIn200.Status != 429 {
            t.Fatal("lowered passthrough fields differ")
          }
          t.Log("named groups, secret URL substitution, aliases, priority and envelopes passed native validation")
        }
      '';
    };
    postTest = ''echo "native passthrough module config passed" > "$out"'';
  };
in {
  checks.cliproxyapi-passthrough-module = pkgs.linkFarm "cliproxyapi-passthrough-module" (lib.mapAttrsToList (name: path: {inherit name path;}) (moduleChecks
    // {
      inherit native secrets;
      existing-clients = regressions.module-ai-inference-instance-clients;
      existing-opencode = regressions.module-ai-inference-opencode-go-credential;
      existing-z-ai = regressions.module-ai-inference-z-ai-credential;
    }));
}
