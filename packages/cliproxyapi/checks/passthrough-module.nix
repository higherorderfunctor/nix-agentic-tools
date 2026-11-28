# Refuse lost aliases/envelopes, secret paths rendered as objects, shared-URL
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
  path = redact.concat ["/client/v4/accounts/" (secret "account") "/ai/run/@cf/cloudflare/clef"];
  fixture = {
    clientKeys.main = {
      key = secret "client";
      routes = [{credential = "cloudflare";} {credential = "system-one";}];
    };
    credentials = {
      cloudflare.apiKey = {
        apis.passthrough = {
          base-url = "https://api.cloudflare.com";
          models = [
            {
              alias = "decision";
              name = "clef";
            }
          ];
          inherit path;
          unwrap = "result";
          usage-path = "result.usage";
        };
        key = secret "cloudflare";
        priority = 30;
      };
      system-one.apiKey = {
        apis.passthrough = {
          base-url = "https://api.systemone.ai";
          models = [
            {
              alias = "decision";
              name = "jev";
            }
          ];
          path = "/inference/v1/decision";
        };
        key = secret "system-one";
        priority = 20;
      };
    };
    enable = true;
    settings.config-version = 8;
  };
  evaluate = backend: change:
    backend {
      ai.cliproxyapi.instances.main = lib.recursiveUpdate fixture change;
    };
  backends = {
    devenv = harness.evalDevenv;
    hm = harness.evalHm;
  };
  failures = result: map (entry: entry.message) (lib.filter (entry: !entry.assertion) result.config.assertions);
  expectedCloudflare = {
    base-url = "https://api.cloudflare.com";
    keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_KEYS_0_API_KEY}";}];
    models = [
      {
        alias = "decision";
        name = "clef";
      }
    ];
    name = "cloudflare";
    path = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_PATH}";
    priority = 30;
    unwrap = "result";
    usage-path = "result.usage";
  };
  expectedSystemOne = {
    base-url = "https://api.systemone.ai";
    keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_PASSTHROUGH_1_KEYS_0_API_KEY}";}];
    models = [
      {
        alias = "decision";
        name = "jev";
      }
    ];
    name = "system-one";
    path = "/inference/v1/decision";
    priority = 20;
  };
  expectedRules = [
    {
      base-urls = ["https://api.cloudflare.com"];
      kind = "apikey";
      provider = "passthrough-cloudflare";
    }
    {
      base-urls = ["https://api.systemone.ai"];
      kind = "apikey";
      provider = "passthrough-system-one";
    }
  ];
  # Native loader receives only synthetic values, through the shared fill engine.
  rendered = cliproxyapi.render (evaluate harness.evalHm {}).config.ai.cliproxyapi.instances.main.settings;
  values = lib.mapAttrs (_: reference:
    if reference == path
    then "/client/v4/accounts/synthetic-account/ai/run/@cf/cloudflare/clef"
    else "synthetic-key")
  rendered.secrets;
  nativeConfig = fill values rendered.content;
  moduleChecks = lib.mapAttrs (backendName: backend:
    harness.mkTest "passthrough-module-${backendName}" (let
      result = evaluate backend {};
      output = cliproxyapi.render result.config.ai.cliproxyapi.instances.main.settings;
      settings = builtins.fromJSON output.content;
      # Force only the declared URL restriction for the type refusal. The
      # conditional element reaches the separate merged-value assertion.
      narrowed = entries:
        evaluate backend {
          settings.access.key-allowlist = [
            {
              api-key = secret "restricted-client";
              credentials = [
                {
                  base-urls = entries;
                  kind = "apikey";
                  provider = "passthrough-cloudflare";
                }
              ];
            }
          ];
        };
      readUrls = evaluated: let
        entries = evaluated.config.ai.cliproxyapi.instances.main.settings.access.key-allowlist;
        restricted = lib.findFirst (entry: entry.api-key == secret "restricted-client") null entries;
      in
        (lib.head restricted.credentials).base-urls;
      urls = ["https://api.cloudflare.com"];
      valid = narrowed urls;
      cases = {
        "allowlist URL restriction accepted" = failures valid == [] && readUrls valid == urls;
        "allowlist accepts a null URL that the renderer would drop" = harness.rejectsChange readUrls {
          inherit valid;
          expected = urls;
          invalid = narrowed [null];
        };
        "allowlist loses the assertion when mkIf removes its URL restriction" = let
          empty = narrowed [(lib.mkIf false "https://api.cloudflare.com")];
        in
          readUrls empty
          == []
          && failures empty == ["ai.cliproxyapi.instances.main: settings.access.key-allowlist[].credentials[].base-urls merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value."];
        "client access retained" = settings.access.api-keys == ["{$CLIPROXYAPI_ACCESS_API_KEYS_0}"];
        "client routed credentials exclude passthrough" = result.config.ai.internal.inferenceInstances.main.clients.main.credentials == [];
        "literal rules retain distinct named identities" = (lib.head settings.access.key-allowlist).credentials == expectedRules;
        "lowering loses a group, adds a group or alters its fields" = failures result == [] && settings.api-keys.passthrough == [expectedCloudflare expectedSystemOne];
        "named path references render with shared engine" = output.secrets.CLIPROXYAPI_API_KEYS_PASSTHROUGH_0_PATH == path;
      };
    in
      harness.checkRows "${backendName}: passthrough module" cases))
  backends;
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
          if g.ProviderKey() != "passthrough-cloudflare" || g.Priority != 30 ||
             g.BaseURL != "https://api.cloudflare.com" || g.Path != "/client/v4/accounts/synthetic-account/ai/run/@cf/cloudflare/clef" ||
             len(g.Models) != 1 || g.Models[0].Alias != "decision" || g.Models[0].Name != "clef" ||
             g.Unwrap == nil || *g.Unwrap != "result" || g.UsagePath == nil || *g.UsagePath != "result.usage" {
            t.Fatal("lowered passthrough fields differ")
          }
          plain := cfg.Passthrough[1]
          if plain.ProviderKey() != "passthrough-system-one" || plain.Priority != 20 ||
             plain.BaseURL != "https://api.systemone.ai" || plain.Path != "/inference/v1/decision" ||
             len(plain.Models) != 1 || plain.Models[0].Alias != "decision" || plain.Models[0].Name != "jev" ||
             plain.Unwrap != nil || plain.UsagePath != nil {
            t.Fatal("lowered plain passthrough fields differ")
          }
          t.Log("named groups, secret path substitution, aliases, priority and envelopes passed native validation")
        }
      '';
    };
    postTest = ''echo "native passthrough module config passed" > "$out"'';
  };
in {
  checks.cliproxyapi-passthrough-module = pkgs.linkFarm "cliproxyapi-passthrough-module" (lib.mapAttrsToList (name: path: {inherit name path;}) (moduleChecks
    // {
      inherit native;
    }));
}
