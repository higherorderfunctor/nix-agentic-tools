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
  # Match the retained prefix-refusal scope without calling its implementation.
  eligible = lib.filter (id: builtins.match "(claude-|glm-|gpt-).*" (lib.toLower id) == null) (builtins.attrNames go);
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
  # Force assertions as well as the JSON output so prefix refusals remain exercised.
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
  # Each backend exercises full static offers, retained defaults, list overrides and identity aliases.
  checks = lib.mapAttrs (backendName: evaluate:
    harness.mkTest "cliproxyapi-catalog-${backendName}" (let
      result = evaluate [fixture];
      catalog = result.config.ai.catalog;
      settings = render result;
      narrowed = render (evaluate [
        fixture
        {
          ai.catalog.providers = {
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
            providers = {
              opencode-go.models = ["configured"];
              z-ai.models = ["configured"];
            };
          };
        }
      ]);
      full = render (evaluate [
        fixture
        {
          ai.catalog.providers = {
            opencode-go.models = builtins.attrNames go;
            z-ai.models = zai.models;
          };
        }
      ]);
      constructed = import ../lib/providers.nix {inherit lib catalog;};
      expectedZai = lib.genAttrs (builtins.attrNames zai.apis) (_: sorted zai.models);
      expectedNarrowGo = {${nativeApi.${lib.head (builtins.attrNames go.${chosen}.api)}} = [chosen];};
      cases = {
        "configured finite lists ignored" = offers narrowed "opencode-go" == expectedNarrowGo && offers narrowed "z-ai" == lib.genAttrs (builtins.attrNames zai.apis) (_: [chosenZai]);
        "configured identity aliases ignored" = offers renamed "opencode-go" == expectedNarrowGo && offers renamed "z-ai" == lib.genAttrs (builtins.attrNames zai.apis) (_: [chosenZai]);
        "dropped extracted offer" = sorted catalog.providers.opencode-go.models == builtins.attrNames go && sorted catalog.providers.z-ai.models == sorted zai.models && lib.all (id: catalog.models ? ${id}) (builtins.attrNames go ++ zai.models);
        # Full catalog lists retain filtered rendering until the prefix refusal is removed.
        "explicit full lists lose eligible rendered models" = offers full "opencode-go" == lib.mapAttrs (_: sorted) expectedGo && offers full "z-ai" == expectedZai;
        "lost alias or missing/wrong maker" =
          lib.all (id: let
            identity = catalog.models.${id};
          in
            expectedMaker id != "" && identity.maker == expectedMaker id && sorted identity.aliases.opencode-go == lib.optional ((go.${id}.canonical_id or null) != null) go.${id}.canonical_id) (builtins.attrNames go)
          && lib.all (id: catalog.models.${id}.maker == "zhipu") zai.models;
        "lost eligible model or wrong native API in rendered defaults" = offers settings "opencode-go" == lib.mapAttrs (_: sorted) expectedGo && offers settings "z-ai" == expectedZai;
        "standalone constructor diverges from module defaults" = lib.mapAttrs (_: vendor: builtins.removeAttrs vendor ["refuses"]) manual.vendors == lib.mapAttrs (_: vendor: builtins.removeAttrs vendor ["refuses"]) constructed.vendors;
      };
      failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
      lib.assertMsg (failures == []) "${backendName}: ${lib.concatStringsSep "; " failures}"))
  backends;
in {
  # One owner check includes both production backends; no model inventory snapshot is maintained.
  checks.cliproxyapi-catalog = pkgs.linkFarm "cliproxyapi-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
