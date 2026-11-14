# Independent extracted-fact properties catch missing contributions and catalog-blind credential defaults.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Expected inventories come directly from extraction, never vendor constructors.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # Loading independently makes a dropped owner contribution visible.
  fact = facts.get (facts.load {dir = ../extracted;}).aggregate;
  # Go owns transport metadata; only identities and offers reach the catalog.
  go = (fact "opencodeGo").models;
  # z.ai's independent model table covers both supported APIs.
  zhipuai = fact "zhipuai";
  # Sets deliberately ignore grant and module merge ordering.
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  # Every extracted offer is eligible, regardless of its maker or id prefix.
  eligible = builtins.attrNames go;
  # This table independently specifies native protocol placement, including Gemini's chat fallback.
  nativeApi = {
    chat-completions = "chat";
    generate-content = "chat";
    messages = "anthropic";
    responses = "responses";
  };
  # Expected per-API model sets are derived from the raw input inventory.
  expectedGo = lib.groupBy (id: nativeApi.${lib.head (builtins.attrNames go.${id}.api)}) eligible;
  # Synthetic secrets use the same references as production instance options.
  redact = import ../../../lib/redact {inherit lib;};
  # Production fixtures exercise vendor construction, lowering and typed settings on both backends.
  fixture.ai.cliproxyapi.instances.main = {
    credentials = lib.genAttrs ["opencode-go" "zhipuai"] (vendor: {
      inherit vendor;
      apiKey.key = redact.file "/run/secrets/catalog-${vendor}";
    });
    enable = true;
    settings.config-version = 8;
  };
  # Render exactly the settings passed to the CPA service launcher.
  cpa = (import ../lib/default.nix {inherit lib;}).cliproxyapi;
  # Standalone construction must stay equivalent without importing any module configuration.
  manual = import ../lib/providers.nix {inherit lib;};
  # Synthetic native metadata refuses transport shapes that CPA cannot lower safely.
  native = api: base_url: {api.${api} = {inherit base_url;};};
  # Synthetic ids keep shape checks independent of release inventories.
  shaped = {
    anthropic = native "messages" "https://go.example/anthropic/v1";
    chat = native "chat-completions" "https://go.example/openai/v1";
  };
  # Force placement and URL checks without evaluating a service derivation.
  builds = models: (builtins.tryEval (builtins.deepSeq (manual.opencodeGo models).apis true)).success;
  # Each property names the malformed input its constructor must reject.
  catalogShapes = {
    "conflicting base URLs accepted" = !(builds (shaped // {other = native "chat-completions" "https://elsewhere.example/v1";}));
    "messages URL without /v1 accepted" = !(builds (shaped // {anthropic = native "messages" "https://go.example/anthropic";}));
    "missing base_url accepted" = !(builds (shaped // {bare.api.responses = {};}));
    "two native APIs accepted" = !(builds (shaped // {two.api = shaped.anthropic.api // shaped.chat.api;}));
    "unknown native API accepted" = !(builds (shaped // {odd = native "embeddings" "https://go.example/openai/v1";}));
    "well-formed catalog rejected" = builds shaped;
  };
  # Use real backend harnesses rather than a fabricated credential option shape.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # API families are independent expected wire-format names.
  families = {
    anthropic = "claude";
    chat = "openai-compatibility";
    responses = "codex";
  };
  # Compare each vendor's rendered model set without secret placeholders or ordering.
  offers = settings: vendor:
    lib.filterAttrs (_: models: models != []) (lib.mapAttrs (_: family:
      sorted (lib.concatMap (block: map (model: model.name) block.models)
        (lib.filter (block: block.name == vendor) (settings.api-keys.${family} or []))))
    families);
  # Force assertions as well as the JSON output so failed instance assertions cannot hide behind rendering.
  render = result:
    assert lib.assertMsg (lib.all (entry: entry.assertion) result.config.assertions) "catalog fixture has failed instance assertions";
      builtins.fromJSON (cpa.render result.config.ai.cliproxyapi.instances.main.settings).content;
  # A singleton native model proves overrides change credentials; Gemini alone lacks a chat URL.
  chosen = lib.head (lib.filter (id: !(go.${id}.api ? generate-content)) eligible);
  # Select by input data rather than pinning a removable release model id.
  chosenZhipuai = lib.head zhipuai.models;
  # Independent maker expectations expose missing identity evidence and namespace drift.
  expectedMaker = id: let
    namespace = lib.head (lib.splitString "/" (go.${id}.canonical_id or ""));
  in
    if id == "iceman-contributor-free"
    then "iceman"
    else namespace;
  # Each backend exercises complete defaults, list overrides and vendor-scoped served spellings.
  checks = lib.mapAttrs (backendName: evaluate:
    harness.mkTest "cliproxyapi-catalog-${backendName}" (let
      result = evaluate [fixture];
      catalog = result.config.ai.catalog;
      settings = render result;
      narrowed = render (evaluate [
        fixture
        {
          ai.catalog.vendors = {
            opencode-go.models = [chosen];
            zhipuai.models = [chosenZhipuai];
          };
        }
      ]);
      renamed = render (evaluate [
        fixture
        {
          ai.catalog = {
            models.configured = {
              source = ["configured identity"];
            };
            vendors = {
              opencode-go.models = ["configured"];
              zhipuai.models = ["configured"];
            };
          };
          ai.cliproxyapi.servedModels = {
            opencode-go.configured = [chosen];
            zhipuai.configured = [chosenZhipuai];
          };
        }
      ]);
      # An explicit Go API override renders every listed model, whatever its maker or spelling.
      overrideResult = evaluate [
        fixture
        {
          ai.cliproxyapi.instances.main.credentials.opencode-go.apiKey.apis = {
            anthropic = null;
            chat = {
              base-url = "https://override.example/v1";
              models = ["claude-fixture" "glm-fixture" "gpt-fixture" "qwen-中文-fixture"];
            };
            responses = null;
          };
        }
      ];
      overridden = render overrideResult;
      # Exclude two makers taken from the extracted Go facts, so no maker name or model id is pinned.
      excluded = lib.take 2 (sorted (map expectedMaker eligible));
      filteredGo = render (evaluate [fixture {ai.cliproxyapi.instances.main.credentials.opencode-go.excludeMakers = excluded;}]);
      expectedFilteredGo = lib.mapAttrs (_: sorted) (lib.groupBy (id: nativeApi.${lib.head (builtins.attrNames go.${id}.api)}) (lib.filter (id: !(lib.elem (expectedMaker id) excluded)) eligible));
      # Synthetic explicit offers exercise alias scope, canonical precedence and unknown maker preservation.
      explicit = exclusions:
        evaluate [
          {
            ai = {
              catalog.models = lib.mapAttrs (_: identity: identity // {source = ["maker exclusion fixture"];}) {
                fixture-blocked = {
                  maker = "fixture-maker";
                };
                fixture-kept = {
                  maker = "fixture-other";
                };
                fixture-null.maker = null;
                fixture-unset = {};
              };
              cliproxyapi.instances.main = {
                enable = true;
                settings.config-version = 8;
                credentials.filtered = {
                  vendor = "opencode-go";
                  excludeMakers = exclusions;
                  apiKey = lib.mkForce {
                    key = redact.file "/run/secrets/filtered";
                    apis = {
                      anthropic = {
                        base-url = "https://filtered.example/anthropic";
                        models = ["fixture-blocked"];
                      };
                      chat = {
                        base-url = "https://filtered.example/chat";
                        models = ["fixture-absent" "fixture-alias" "fixture-blocked" "fixture-kept" "fixture-null" "fixture-unset"];
                      };
                    };
                  };
                };
                clientKeys.main = {
                  key = redact.file "/run/secrets/client-filtered";
                  routes = [{credential = "filtered";}];
                };
              };
              cliproxyapi.servedModels = {
                opencode-go.fixture-blocked = ["fixture-alias"];
                zhipuai.fixture-kept = ["fixture-alias" "fixture-blocked"];
              };
            };
          }
        ];
      explicitResult = explicit ["fixture-maker"];
      explicitSettings = render explicitResult;
      expectedExplicit = ["fixture-absent" "fixture-kept" "fixture-null" "fixture-unset"];
      # Force merged credential normalization itself, before rendering or assertion collection.
      acceptsExclusions = credential:
        (builtins.tryEval (builtins.deepSeq
          (evaluate [
            {
              ai.cliproxyapi.instances.main.credentials.bad = credential;
            }
          ]).config.ai.cliproxyapi.instances.main.credentials
          true)).success;
      # Type refusals exercise whitespace normalization with non-rotating model names.
      acceptsModel = name:
        (builtins.tryEval (builtins.deepSeq
          (evaluate [
            fixture
            {
              ai.cliproxyapi.instances.main.credentials.opencode-go.apiKey.apis.chat.models = [name];
            }
          ]).config.ai.cliproxyapi.instances.main.credentials
          true)).success;
      # z.ai tool defaults and explicit disabling are provider behavior, owned here.
      zhipuaiOverride = overrides: evaluate [fixture {ai.cliproxyapi.instances.main.credentials.zhipuai.apiKey = overrides;}];
      disabled = render (zhipuaiOverride {
        codexShellArgCleanup = false;
        toolAliases = {};
      });
      zhipuaiCustomModels = render (zhipuaiOverride {
        apis = {
          anthropic = null;
          chat.base-url = "https://zhipuai-override.example/v1";
        };
        models = ["fixture-zhipuai-model"];
      });
      customized = render (zhipuaiOverride {toolAliases.ToolSearch = "SearchProxy";});
      # Select named blocks rather than their incidental render order.
      blocks = value: family: vendor: lib.filter (entry: entry.name == vendor) (value.api-keys.${family} or []);
      block = value: family: vendor: lib.head (blocks value family vendor);
      # Native base URLs are independently extracted; messages drops the executor's /v1 suffix.
      expectedUrl = api: let
        ids = lib.filter (id: nativeApi.${lib.head (builtins.attrNames go.${id}.api)} == api && !(go.${id}.api ? generate-content)) eligible;
        entry = go.${lib.head ids};
        url = entry.api.${lib.head (builtins.attrNames entry.api)}.base_url;
      in
        if api == "anthropic"
        then lib.removeSuffix "/v1" url
        else url;
      # A valid maker-wide offer must fail at the credential vendor option, before construction.
      acceptsMakerOffer = vendor:
        (builtins.tryEval
          (evaluate [
            fixture
            {
              ai.catalog.vendors.${vendor} = {
                maker = "fixture-maker";
                models = null;
              };
            }
          ]).config.ai.cliproxyapi.instances.main.credentials.${
            vendor
          }.vendor).success;
      # Missing identities must throw before Go attribute lookup or z.ai rendering can accept them.
      acceptsUnknownIdentity = vendor:
        (builtins.tryEval (builtins.deepSeq
          (evaluate [fixture {ai.catalog.vendors.${vendor}.models = ["fixture-missing-identity"];}]).config.ai.cliproxyapi.instances.main.credentials.${vendor}
          true)).success;
      # A selected identity cannot silently render an unmeasured owner spelling.
      acceptsUnknownServed = vendor: id:
        (builtins.tryEval (builtins.deepSeq
          (evaluate [
            fixture
            {
              ai.catalog.vendors.${vendor}.models = [id];
              ai.cliproxyapi.servedModels.${vendor}.${id} = ["fixture-unmeasured"];
            }
          ]).config.ai.cliproxyapi.instances.main.credentials.${
            vendor
          }
          true)).success;
      # Repeated owner declarations describe one offer, including equal-priority module merges.
      repeated = vendor: id:
        render (evaluate [
          fixture
          {ai.catalog.vendors.${vendor}.models = [id id];}
          {ai.catalog.vendors.${vendor}.models = [id];}
        ]);
      # No exclusive flag is set: maker filtering itself must refuse the shared alias.
      ambiguousExclusion = evaluate [
        {
          ai = {
            catalog.models = lib.genAttrs ["fixture-first" "fixture-second"] (_: {
              maker = "fixture-maker";
              source = ["maker exclusion fixture"];
            });
            cliproxyapi.servedModels.opencode-go = lib.genAttrs ["fixture-first" "fixture-second"] (_: ["fixture-shared"]);
            cliproxyapi.instances.main.credentials.filtered = {
              excludeMakers = ["fixture-maker"];
              apiKey = {
                apis.chat.base-url = "https://filtered.example/chat";
                key = redact.file "/run/secrets/filtered";
                models = ["fixture-shared"];
              };
            };
          };
        }
      ];
      # The null API-key guard preserves the named exactly-one assertion for neither-kind inputs.
      neitherKind = evaluate [
        {
          ai.cliproxyapi.instances.main = {
            credentials.bad.excludeMakers = ["anthropic"];
            enable = true;
            settings.config-version = 8;
          };
        }
      ];
      constructed = import ../lib/providers.nix {inherit lib catalog;};
      expectedZhipuai = lib.genAttrs (builtins.attrNames zhipuai.apis) (_: sorted zhipuai.models);
      expectedNarrowGo = {${nativeApi.${lib.head (builtins.attrNames go.${chosen}.api)}} = [chosen];};
      cases =
        catalogShapes
        // {
          "ambiguous exclusion alias accepted without exclusive" = let
            resolver = import ../lib/providers.nix {
              inherit lib;
              catalog = ambiguousExclusion.config.ai.catalog;
              servedModels = ambiguousExclusion.config.ai.cliproxyapi.servedModels;
            };
          in
            (resolver.canonical null "fixture-shared").errors
            == ["ambiguous model alias `fixture-shared`: fixture-first, fixture-second; use a canonical catalog id."]
            && !(builtins.tryEval (builtins.deepSeq ambiguousExclusion.config.ai.cliproxyapi.instances.main.credentials true)).success;
          "configured finite lists ignored" = offers narrowed "opencode-go" == expectedNarrowGo && offers narrowed "zhipuai" == lib.genAttrs (builtins.attrNames zhipuai.apis) (_: [chosenZhipuai]);
          "configured vendor-scoped served spellings ignored" = offers renamed "opencode-go" == expectedNarrowGo && offers renamed "zhipuai" == lib.genAttrs (builtins.attrNames zhipuai.apis) (_: [chosenZhipuai]);
          "dropped extracted offer" = sorted catalog.vendors.opencode-go.models == builtins.attrNames go && sorted catalog.vendors.zhipuai.models == sorted zhipuai.models && lib.all (id: catalog.models ? ${id}) (builtins.attrNames go ++ zhipuai.models);
          "empty exclusions change rendered defaults" = render (evaluate [fixture {ai.cliproxyapi.instances.main.credentials.opencode-go.excludeMakers = [];}]) == settings;
          "excluded explicit aliases survive or unknown makers disappear" = offers explicitSettings "filtered" == {chat = sorted expectedExplicit;};
          "excluded models remain in inference registry" =
            explicitResult.config.ai.internal.inferenceInstances.main.clients.main.credentials
            == [
              {
                name = "filtered";
                models = expectedExplicit;
              }
            ];
          "explicit Go overrides refused or APIs retained" = offers overridden "opencode-go" == {chat = ["claude-fixture" "glm-fixture" "gpt-fixture" "qwen-中文-fixture"];} && (block overridden "openai-compatibility" "opencode-go").base-url == "https://override.example/v1";
          "filtered sole API does not resolve its grant" =
            (lib.head explicitSettings.access.key-allowlist).credentials
            == [
              {
                base-urls = ["https://filtered.example/chat"];
                kind = "apikey";
                provider = "openai-compatible-filtered";
              }
            ];
          "lost owner mapping or missing/wrong maker" =
            lib.all (id: let
              identity = catalog.models.${id};
            in
              expectedMaker id != "" && identity.maker == expectedMaker id && sorted result.config.ai.cliproxyapi.servedModels.opencode-go.${id} == sorted ([id] ++ lib.optional ((go.${id}.canonical_id or null) != null) go.${id}.canonical_id)) (builtins.attrNames go)
            && lib.all (id: catalog.models.${id}.maker == "zhipuai") zhipuai.models;
          "lost model or wrong native API in rendered defaults" = offers settings "opencode-go" == lib.mapAttrs (_: sorted) expectedGo && offers settings "zhipuai" == expectedZhipuai;
          "maker exclusion ignored or native APIs changed" = offers filteredGo "opencode-go" == expectedFilteredGo;
          "maker-wide vendor accepted before finite constructor" = lib.all (vendor: !(acceptsMakerOffer vendor)) ["opencode-go" "zhipuai"];
          "model edge whitespace accepted" = !(acceptsModel " fixture-model") && !(acceptsModel "fixture-model ");
          "native base URLs changed" = lib.all (api: (block settings families.${api} "opencode-go").base-url == expectedUrl api) (builtins.attrNames expectedGo);
          "neither-kind exclusions hide exactly-one assertion" = lib.any (entry: !entry.assertion && entry.message == "ai.cliproxyapi.instances.main.credentials.bad: declare exactly one of oauth or apiKey.") neitherKind.config.assertions;
          "nonempty OAuth exclusions accepted" =
            !(acceptsExclusions {
              excludeMakers = ["anthropic"];
              oauth = {
                vendor = "claude";
                account = redact.file "/run/secrets/bad";
              };
            });
          "repeated owner offers fail or render duplicate models" = lib.all (entry: let
            rendered = repeated entry.vendor entry.id;
            actual = lib.concatMap (api: (block rendered families.${api} entry.vendor).models) entry.apis;
          in
            actual == map (_: {name = entry.id;}) entry.apis) [
            {
              apis = [nativeApi.${lib.head (builtins.attrNames go.${chosen}.api)}];
              id = chosen;
              vendor = "opencode-go";
            }
            {
              apis = builtins.attrNames zhipuai.apis;
              id = chosenZhipuai;
              vendor = "zhipuai";
            }
          ];
          "session header missing from API block" = lib.all (api: (block result.config.ai.cliproxyapi.instances.main.settings families.${api} "opencode-go").headers.x-opencode-session == manual.literalHeader pkgs "$CPA-SESSION-ID") (builtins.attrNames expectedGo);
          "standalone constructor diverges from module defaults" = manual.vendors == constructed.vendors;
          "unknown identity reaches vendor transport defaults" = lib.all (vendor: !(acceptsUnknownIdentity vendor)) ["opencode-go" "zhipuai"];
          "unknown served id reaches vendor transport defaults" = !(acceptsUnknownServed "opencode-go" chosen) && !(acceptsUnknownServed "zhipuai" chosenZhipuai);
          "unknown maker exclusion accepted before rendering" =
            !(acceptsExclusions {
              excludeMakers = ["fixture-typo"];
              apiKey = {
                key = redact.file "/run/secrets/bad";
                apis.chat.base-url = "https://bad.example";
                models = ["fixture-model"];
              };
            });
          "vendor tool defaults lost" = (block settings "claude" "zhipuai").tool-aliases == {ToolSearch = "ToolSearch_";} && (block settings "openai-compatibility" "zhipuai").codex-shell-arg-cleanup && lib.all (api: let value = block settings families.${api} "opencode-go"; in !(value ? tool-aliases) && !(value ? codex-shell-arg-cleanup)) (builtins.attrNames expectedGo);
          "z.ai explicit model or API overrides ignored" = offers zhipuaiCustomModels "zhipuai" == {chat = ["fixture-zhipuai-model"];} && (block zhipuaiCustomModels "openai-compatibility" "zhipuai").base-url == "https://zhipuai-override.example/v1";
          "z.ai explicit tool overrides ignored" = (block customized "claude" "zhipuai").tool-aliases == {ToolSearch = "SearchProxy";} && !((block disabled "claude" "zhipuai") ? tool-aliases) && !((block disabled "openai-compatibility" "zhipuai") ? codex-shell-arg-cleanup);
          "z.ai extracted API URL ignored" = lib.all (api: (block settings families.${api} "zhipuai").base-url == zhipuai.apis.${api}.base-url) (builtins.attrNames zhipuai.apis);
          "z.ai unexpected vendor headers" = lib.all (api: !((block settings families.${api} "zhipuai") ? headers)) (builtins.attrNames zhipuai.apis);
        };
      failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
      lib.assertMsg (failures == []) "${backendName}: ${lib.concatStringsSep "; " failures}"))
  backends;
in {
  # One owner check includes both production backends; no model inventory snapshot is maintained.
  checks.cliproxyapi-catalog = pkgs.linkFarm "cliproxyapi-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
