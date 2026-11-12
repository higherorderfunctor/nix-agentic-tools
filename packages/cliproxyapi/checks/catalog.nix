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
  zai = fact "zAi";
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
    credentials = lib.genAttrs ["opencode-go" "z-ai"] (vendor: {
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
  chosenZai = lib.head zai.models;
  # Independent maker expectations expose missing identity evidence and namespace drift.
  expectedMaker = id: let
    namespace = lib.head (lib.splitString "/" (go.${id}.canonical_id or ""));
  in
    if id == "iceman-contributor-free"
    then "iceman"
    else if namespace == "zhipuai"
    then "zhipu"
    else namespace;
  # Each backend exercises complete defaults, list overrides and identity aliases.
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
            z-ai.models = [chosenZai];
          };
        }
      ]);
      renamed = render (evaluate [
        fixture
        {
          ai.catalog = {
            models.configured = {
              aliases = {
                opencode-go = [chosen];
                z-ai = [chosenZai];
              };
              source = ["configured identity"];
            };
            vendors = {
              opencode-go.models = ["configured"];
              z-ai.models = ["configured"];
            };
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
      zaiOverride = overrides: evaluate [fixture {ai.cliproxyapi.instances.main.credentials.z-ai.apiKey = overrides;}];
      disabled = render (zaiOverride {
        codexShellArgCleanup = false;
        toolAliases = {};
      });
      zaiCustomModels = render (zaiOverride {
        apis = {
          anthropic = null;
          chat.base-url = "https://zai-override.example/v1";
        };
        models = ["fixture-zai-model"];
      });
      customized = render (zaiOverride {toolAliases.ToolSearch = "SearchProxy";});
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
      constructed = import ../lib/providers.nix {inherit lib catalog;};
      expectedZai = lib.genAttrs (builtins.attrNames zai.apis) (_: sorted zai.models);
      expectedNarrowGo = {${nativeApi.${lib.head (builtins.attrNames go.${chosen}.api)}} = [chosen];};
      cases =
        catalogShapes
        // {
          "configured finite lists ignored" = offers narrowed "opencode-go" == expectedNarrowGo && offers narrowed "z-ai" == lib.genAttrs (builtins.attrNames zai.apis) (_: [chosenZai]);
          "configured identity aliases ignored" = offers renamed "opencode-go" == expectedNarrowGo && offers renamed "z-ai" == lib.genAttrs (builtins.attrNames zai.apis) (_: [chosenZai]);
          "dropped extracted offer" = sorted catalog.vendors.opencode-go.models == builtins.attrNames go && sorted catalog.vendors.z-ai.models == sorted zai.models && lib.all (id: catalog.models ? ${id}) (builtins.attrNames go ++ zai.models);
          "explicit Go overrides refused or APIs retained" = offers overridden "opencode-go" == {chat = ["claude-fixture" "glm-fixture" "gpt-fixture" "qwen-中文-fixture"];} && (block overridden "openai-compatibility" "opencode-go").base-url == "https://override.example/v1";
          "lost alias or missing/wrong maker" =
            lib.all (id: let
              identity = catalog.models.${id};
            in
              expectedMaker id != "" && identity.maker == expectedMaker id && sorted identity.aliases.opencode-go == lib.optional ((go.${id}.canonical_id or null) != null) go.${id}.canonical_id) (builtins.attrNames go)
            && lib.all (id: catalog.models.${id}.maker == "zhipu") zai.models;
          "lost model or wrong native API in rendered defaults" = offers settings "opencode-go" == lib.mapAttrs (_: sorted) expectedGo && offers settings "z-ai" == expectedZai;
          "maker-wide vendor accepted before finite constructor" = lib.all (vendor: !(acceptsMakerOffer vendor)) ["opencode-go" "z-ai"];
          "model edge whitespace accepted" = !(acceptsModel " fixture-model") && !(acceptsModel "fixture-model ");
          "native base URLs changed" = lib.all (api: (block settings families.${api} "opencode-go").base-url == expectedUrl api) (builtins.attrNames expectedGo);
          "session header missing from API block" = lib.all (api: (block result.config.ai.cliproxyapi.instances.main.settings families.${api} "opencode-go").headers.x-opencode-session == manual.literalHeader pkgs "$CPA-SESSION-ID") (builtins.attrNames expectedGo);
          "standalone constructor diverges from module defaults" = manual.vendors == constructed.vendors;
          "vendor tool defaults lost" = (block settings "claude" "z-ai").tool-aliases == {ToolSearch = "ToolSearch_";} && (block settings "openai-compatibility" "z-ai").codex-shell-arg-cleanup && lib.all (api: let value = block settings families.${api} "opencode-go"; in !(value ? tool-aliases) && !(value ? codex-shell-arg-cleanup)) (builtins.attrNames expectedGo);
          "z.ai explicit model or API overrides ignored" = offers zaiCustomModels "z-ai" == {chat = ["fixture-zai-model"];} && (block zaiCustomModels "openai-compatibility" "z-ai").base-url == "https://zai-override.example/v1";
          "z.ai explicit tool overrides ignored" = (block customized "claude" "z-ai").tool-aliases == {ToolSearch = "SearchProxy";} && !((block disabled "claude" "z-ai") ? tool-aliases) && !((block disabled "openai-compatibility" "z-ai") ? codex-shell-arg-cleanup);
          "z.ai extracted API URL ignored" = lib.all (api: (block settings families.${api} "z-ai").base-url == zai.apis.${api}.base-url) (builtins.attrNames zai.apis);
          "z.ai unexpected vendor headers" = lib.all (api: !((block settings families.${api} "z-ai") ? headers)) (builtins.attrNames zai.apis);
        };
      failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
      lib.assertMsg (failures == []) "${backendName}: ${lib.concatStringsSep "; " failures}"))
  backends;
in {
  # One owner check includes both production backends; no model inventory snapshot is maintained.
  checks.cliproxyapi-catalog = pkgs.linkFarm "cliproxyapi-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
