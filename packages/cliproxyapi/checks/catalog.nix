# cspell:ignore hungerg
# The Home Manager and devenv harnesses render credential defaults from the merged catalog.
# Both compare the rendered routes with the extracted vendor inventories.
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
  # CPA serves the chat inventory regardless of maker or id prefix.
  eligible = builtins.attrNames (lib.filterAttrs (_: model: model.type == "chat") go);
  # Read membership by protocol, independently of the constructor's native
  # API ordering and special-case selection. Gemini is also tested below
  # with fixed models and URLs that cannot drift with the release inventory.
  advertises = protocol: lib.filter (id: go.${id}.api ? ${protocol}) eligible;
  nativeProtocols = {
    anthropic = "messages";
    chat = "chat-completions";
    responses = "responses";
  };
  expectedGo = lib.filterAttrs (_: ids: ids != []) (lib.mapAttrs (family: protocol:
    sorted (advertises protocol ++ lib.optionals (family == "chat") (advertises "generate-content")))
  nativeProtocols);
  expectedPlacement = id: lib.findFirst (family: lib.elem id expectedGo.${family}) null (builtins.attrNames expectedGo);
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
  goVendor = import ../lib/vendors/opencode-go.nix {inherit lib;};
  # Synthetic native metadata refuses transport shapes that CPA cannot lower safely.
  native = api: base_url: {api.${api} = {inherit base_url;};};
  # Synthetic ids keep shape checks independent of release inventories.
  shaped = {
    anthropic = native "messages" "https://go.example/anthropic/v1";
    chat = native "chat-completions" "https://go.example/openai/v1";
  };
  # Both Gemini protocols advertise Google's URL. Only a native chat model supplies the chat URL.
  gemini = {
    api = lib.genAttrs ["generate-content" "interactions"] (_: {base_url = "https://go.example/google/v1beta";});
    recommended_api = "interactions";
  };
  # Force the standalone transport constructor rather than a service derivation.
  readApis = models: (manual.opencodeGo models).apis;
  expectedShape = {
    anthropic = {
      base-url = "https://go.example/anthropic";
      models = ["anthropic"];
    };
    chat = {
      base-url = "https://go.example/openai/v1";
      models = ["chat"];
    };
  };
  withGemini = shaped // {gemini-4-argon = gemini;};
  expectedGemini = expectedShape // {chat = expectedShape.chat // {models = ["chat" "gemini-4-argon"];};};
  refusesShape = invalid:
    harness.rejectsChange readApis {
      expected = expectedShape;
      inherit invalid;
      valid = shaped;
    };
  refusesGemini = invalid:
    harness.rejectsChange readApis {
      expected = expectedGemini;
      inherit invalid;
      valid = withGemini;
    };
  # These standalone cases need neither module backend.
  catalogShapes = {
    "conflicting base URLs accepted" = refusesShape (shaped // {other = native "chat-completions" "https://elsewhere.example/v1";});
    "Gemini exception applied to an unrelated model id" = refusesGemini (shaped // {other = gemini;});
    "Gemini pair accepted despite a missing interactions URL" = refusesGemini (shaped // {gemini-4-argon.api = gemini.api // {interactions = {};};});
    "Gemini pair skips validation of the unused interactions URL" = refusesGemini (shaped // {gemini-4-argon.api = gemini.api // {interactions.base_url = "not a url";};});
    "interactions alone accepted" = refusesGemini (shaped // {gemini-4-argon.api = {inherit (gemini.api) interactions;};});
    "messages URL without /v1 accepted" = refusesShape (shaped // {anthropic = native "messages" "https://go.example/anthropic";});
    "missing base_url accepted" = refusesShape (shaped // {bare.api.responses = {};});
    # Fails if a model without canonical_id gets "" or its owned_by vendor as maker.
    "missing canonical_id given a maker" =
      lib.mapAttrs (_: identity: identity.maker) (goVendor.identitiesOf {
        stealth.owned_by = "opencode";
      })
      == {
        stealth = null;
      };
    "non-chat models contribute identities or served spellings" = lib.all (id:
      !(goVendor.catalog.models ? ${id}) && !(goVendor.servedModels ? ${id}))
    (lib.subtractLists eligible (builtins.attrNames go));
    "non-chat models enter routes" =
      readApis (shaped
        // {
          decision = {type = "decision";} // shaped.chat;
          embedding = {type = "embedding";} // shaped.chat;
        })
      == expectedShape;
    "unknown native API accepted" = refusesShape (shaped // {chat = native "embeddings" "https://go.example/openai/v1";});
    "unrelated native API pair accepted" = refusesGemini (shaped // {gemini-4-argon.api = shaped.anthropic.api // shaped.chat.api;});
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
  # Independent maker expectations expose namespace drift and invented makers.
  # Stealth models with a routing preset expect their hand-written placeholder;
  # any other model without canonical_id has an undisclosed maker, expected as null.
  expectedMaker = id:
    if id == "hungerg-free"
    then "hungerg"
    else if id == "iceman-contributor-free"
    then "iceman"
    else if go.${id} ? canonical_id
    then lib.head (lib.splitString "/" go.${id}.canonical_id)
    else null;
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
      # Empty spelling overrides clear owner aliases while constructors keep each canonical id.
      clearedAliasesResult = evaluate [
        fixture
        {
          ai.cliproxyapi.servedModels = {
            opencode-go.beam-free = [];
            zhipuai.${chosenZhipuai} = [];
          };
        }
      ];
      clearedAliases = render clearedAliasesResult;
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
      # Exclude two known makers taken from the extracted Go facts, so no maker name or model id is pinned.
      excluded = lib.take 2 (sorted (lib.filter (maker: maker != null) (map expectedMaker eligible)));
      filteredGo = render (evaluate [fixture {ai.cliproxyapi.instances.main.credentials.opencode-go.excludeMakers = excluded;}]);
      expectedFilteredGo = lib.filterAttrs (_: ids: ids != []) (lib.mapAttrs (_: lib.filter (id: !(lib.elem (expectedMaker id) excluded))) expectedGo);
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
      readExclusions = credential:
        (evaluate [{ai.cliproxyapi.instances.main.credentials.bad = credential;}]).config.ai.cliproxyapi.instances.main.credentials.bad.excludeMakers;
      oauthCredential.oauth = {
        account = redact.file "/run/secrets/bad";
        vendor = "claude";
      };
      explicitCredential.apiKey = {
        apis.chat.base-url = "https://bad.example";
        key = redact.file "/run/secrets/bad";
        models = ["fixture-model"];
      };
      # Read the merged option that owns the edge restriction, not every credential.
      modelsWith = name:
        (evaluate [
          fixture
          {ai.cliproxyapi.instances.main.credentials.opencode-go.apiKey.apis.chat.models = [name];}
        ]).config.ai.cliproxyapi.instances.main.credentials.opencode-go.apiKey.apis.chat.models;
      refusesEdge = invalid:
        harness.rejectsChange modelsWith {
          expected = ["fixture-model"];
          inherit invalid;
          valid = "fixture-model";
        };
      # z.ai tool defaults and explicit disabling are provider behavior, owned here.
      zhipuaiOverride = overrides: evaluate [fixture {ai.cliproxyapi.instances.main.credentials.zhipuai.apiKey = overrides;}];
      disabled = render (zhipuaiOverride {
        codexShellArgCleanup = false;
        toolAliases = {};
      });
      codingPlanUrl = "https://api.z.ai/api/coding/paas/v4";
      codingPlan = render (zhipuaiOverride {
        apis.chat.base-url = codingPlanUrl;
        models = ["glm-5.4"];
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
      # For each CPA family, derive the URL the rendered endpoint check expects from a native offer.
      # The messages executor appends /v1 itself.
      expectedUrl = api: let
        protocol = nativeProtocols.${api};
        id = lib.head (advertises protocol);
        url = go.${id}.api.${protocol}.base_url;
      in
        if api == "anthropic"
        then lib.removeSuffix "/v1" url
        else url;
      # A valid maker-wide offer must fail at the credential vendor option, before construction.
      vendorCredential = vendor: changes:
        (evaluate [fixture changes]).config.ai.cliproxyapi.instances.main.credentials.${vendor};
      refusesMakerOffer = vendor:
        harness.rejectsChange (change: (vendorCredential vendor change).vendor) {
          expected = vendor;
          invalid.ai.catalog.vendors.${vendor} = {
            maker = "fixture-maker";
            models = null;
          };
          valid = {};
        };
      # Read the default API model list that requires a declared identity.
      refusesUnknownIdentity = vendor: readModels: id: let
        select = modelId: {ai.catalog.vendors.${vendor}.models = [modelId];};
      in
        harness.rejectsChange (change: readModels (vendorCredential vendor change).apiKey) {
          expected = [id];
          invalid = select "fixture-missing-identity";
          valid = select id;
        };
      # Go transport metadata is measured; a declared identity with no match still refuses.
      customGo = spelling: {
        ai.catalog = {
          models.fixture-go-custom.source = ["configured custom Go model"];
          vendors.opencode-go.models = ["fixture-go-custom"];
        };
        ai.cliproxyapi.servedModels.opencode-go.fixture-go-custom = [spelling];
      };
      # Repeated owner declarations describe one offer, including equal-priority module merges.
      repeated = vendor: id:
        render (evaluate [
          fixture
          {ai.catalog.vendors.${vendor}.models = [id id];}
          {ai.catalog.vendors.${vendor}.models = [id];}
        ]);
      # No exclusive flag is set: maker filtering itself must refuse the shared alias.
      exclusionAlias = spelling:
        evaluate [
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
                  models = [spelling];
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
      unmeasuredGoAlias = render (evaluate [
        fixture
        {
          ai.catalog.vendors.opencode-go.models = [chosen];
          ai.cliproxyapi.servedModels.opencode-go.${chosen} = ["fixture-unmeasured"];
        }
      ]);
      customZhipuai = render (evaluate [
        fixture
        {
          ai.catalog = {
            models.fixture-zhipuai-custom.source = ["configured custom Zhipuai model"];
            vendors.zhipuai.models = ["fixture-zhipuai-custom"];
          };
        }
      ]);
      expectedNarrowGo = {${expectedPlacement chosen} = [chosen];};
      cases = {
        "ambiguous exclusion alias accepted without exclusive" = harness.rejectsChange (spelling: (exclusionAlias spelling).config.ai.cliproxyapi.instances.main.credentials.filtered.apiKey.apis.chat) {
          expected = null;
          invalid = "fixture-shared";
          valid = "fixture-first";
        };
        "configured finite lists ignored" = offers narrowed "opencode-go" == expectedNarrowGo && offers narrowed "zhipuai" == lib.genAttrs (builtins.attrNames zhipuai.apis) (_: [chosenZhipuai]);
        "configured vendor-scoped served spellings ignored" = offers renamed "opencode-go" == expectedNarrowGo && offers renamed "zhipuai" == lib.genAttrs (builtins.attrNames zhipuai.apis) (_: [chosenZhipuai]);
        "custom Zhipuai identity loses id fallback" = offers customZhipuai "zhipuai" == lib.genAttrs (builtins.attrNames zhipuai.apis) (_: ["fixture-zhipuai-custom"]);
        "declared unmatched Go identity reaches vendor transport defaults" = harness.rejectsChange (spelling: (vendorCredential "opencode-go" (customGo spelling)).apiKey.apis.${expectedPlacement chosen}.models) {
          expected = [chosen];
          invalid = "fixture-go-unmeasured";
          valid = chosen;
        };
        "dropped extracted offer" = sorted catalog.vendors.opencode-go.models == eligible && sorted catalog.vendors.zhipuai.models == sorted zhipuai.models;
        "empty served spellings lost aliases or canonical fallback" =
          clearedAliasesResult.config.ai.cliproxyapi.servedModels.opencode-go.beam-free
          == []
          && clearedAliasesResult.config.ai.cliproxyapi.servedModels.zhipuai.${chosenZhipuai} == []
          && offers clearedAliases "opencode-go" == offers settings "opencode-go"
          && offers clearedAliases "zhipuai" == offers settings "zhipuai";
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
        "lost owner mapping or wrong or invented maker" =
          lib.all (id: let
            identity = catalog.models.${id};
          in
            identity.maker == expectedMaker id && sorted result.config.ai.cliproxyapi.servedModels.opencode-go.${id} == sorted ([id] ++ lib.optional ((go.${id}.canonical_id or null) != null) go.${id}.canonical_id))
          eligible
          && lib.all (id: catalog.models.${id}.maker == "zhipuai") zhipuai.models;
        "lost model or wrong native API in rendered defaults" = offers settings "opencode-go" == expectedGo && offers settings "zhipuai" == expectedZhipuai;
        "maker exclusion ignored or native APIs changed" = offers filteredGo "opencode-go" == expectedFilteredGo;
        "maker-wide vendor accepted before finite constructor" = lib.all refusesMakerOffer ["opencode-go" "zhipuai"];
        "model accepts a non-ASCII trailing space" = refusesEdge "fixture-model ";
        "model accepts a printable-space leading edge" = refusesEdge " fixture-model";
        "native base URLs changed" = lib.all (api: (block settings families.${api} "opencode-go").base-url == expectedUrl api) (builtins.attrNames expectedGo);
        "neither-kind exclusions hide exactly-one assertion" = lib.any (entry: !entry.assertion && entry.message == "ai.cliproxyapi.instances.main.credentials.bad: declare exactly one of oauth or apiKey.") neitherKind.config.assertions;
        "nonempty OAuth exclusions accepted" = harness.rejectsChange readExclusions {
          expected = [];
          invalid = oauthCredential // {excludeMakers = ["anthropic"];};
          valid = oauthCredential;
        };
        "repeated owner offers fail or render duplicate models" = let
          rendered = repeated "zhipuai" chosenZhipuai;
        in
          lib.all (api: (block rendered families.${api} "zhipuai").models == [{name = chosenZhipuai;}]) (builtins.attrNames zhipuai.apis);
        "session header missing from API block" = lib.all (api: (block result.config.ai.cliproxyapi.instances.main.settings families.${api} "opencode-go").headers.x-opencode-session == manual.literalHeader pkgs "$CPA-SESSION-ID") (builtins.attrNames expectedGo);
        "standalone constructor diverges from module defaults" = manual.vendors == constructed.vendors;
        "unknown maker exclusion accepted before rendering" = harness.rejectsChange readExclusions {
          expected = ["anthropic"];
          invalid = explicitCredential // {excludeMakers = ["fixture-typo"];};
          valid = explicitCredential // {excludeMakers = ["anthropic"];};
        };
        "unknown Zhipuai identity reaches vendor transport defaults" = refusesUnknownIdentity "zhipuai" (apiKey: apiKey.models) chosenZhipuai;
        "unmeasured Go alias drops canonical id fallback" = offers unmeasuredGoAlias "opencode-go" == expectedNarrowGo;
        "vendor tool defaults lost" = (block settings "claude" "zhipuai").tool-aliases == {ToolSearch = "ToolSearch_";} && (block settings "openai-compatibility" "zhipuai").codex-shell-arg-cleanup && lib.all (api: let value = block settings families.${api} "opencode-go"; in !(value ? tool-aliases) && !(value ? codex-shell-arg-cleanup)) (builtins.attrNames expectedGo);
        "z.ai Coding Plan identities missing or offered by default" =
          lib.all (id: catalog.models.${id}.maker == "zhipuai" && !(lib.elem id catalog.vendors.zhipuai.models)) zhipuai.codingPlanOnly;
        "z.ai Coding Plan override did not render GLM-5.4" =
          (offers codingPlan "zhipuai").chat
          == ["glm-5.4"]
          && (block codingPlan "openai-compatibility" "zhipuai").base-url == codingPlanUrl;
        "z.ai explicit model or API overrides ignored" = offers zhipuaiCustomModels "zhipuai" == {chat = ["fixture-zhipuai-model"];} && (block zhipuaiCustomModels "openai-compatibility" "zhipuai").base-url == "https://zhipuai-override.example/v1";
        "z.ai explicit tool overrides ignored" = (block customized "claude" "zhipuai").tool-aliases == {ToolSearch = "SearchProxy";} && !((block disabled "claude" "zhipuai") ? tool-aliases) && !((block disabled "openai-compatibility" "zhipuai") ? codex-shell-arg-cleanup);
        "z.ai extracted API URL ignored" = lib.all (api: (block settings families.${api} "zhipuai").base-url == zhipuai.apis.${api}.base-url) (builtins.attrNames zhipuai.apis);
        "z.ai unexpected vendor headers" = lib.all (api: !((block settings families.${api} "zhipuai") ? headers)) (builtins.attrNames zhipuai.apis);
      };
    in
      harness.checkRows "${backendName}: CPA catalog" cases))
  backends;
in {
  # One owner check includes both production backends; no model inventory snapshot is maintained.
  checks.cliproxyapi-catalog = pkgs.linkFarm "cliproxyapi-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) (checks
    // {
      standalone = harness.mkTest "cliproxyapi-catalog-standalone" (harness.checkRows "standalone CPA catalog" catalogShapes);
    }));
}
