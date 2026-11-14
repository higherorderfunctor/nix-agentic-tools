# OpenCode Go defaults and native-API placement, shared by credentials and synthetic checks.
{lib}: let
  # Read the measured Go catalog where its vendor defaults are built.
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  # Use CPA's aggregate so missing or divergent vendor facts fail at their source.
  fact = facts.get (facts.load {dir = ../../extracted;}).aggregate;
  # Keep transport metadata local; catalog contributions contain identities only.
  extracted = (fact "opencodeGo").models;
  # canonical_id names the maker; owned_by names the serving vendor instead.
  identities =
    lib.mapAttrs (id: model: let
      canonical = model.canonical_id or null;
      namespace =
        if canonical == null
        then null
        else lib.head (lib.splitString "/" canonical);
    in {
      maker =
        if id == "iceman-contributor-free"
        then "iceman"
        else namespace;
      source =
        ["cliproxyapi:opencodeGo.models.${id}"]
        # The upstream identity is undisclosed, not evidence for another maker.
        ++ lib.optional (id == "iceman-contributor-free") "packages/delegate-routing/lib/opencode-go.nix: maker undisclosed";
    })
    extracted;
  # External spellings belong to this owner, never the shared identity catalog.
  servedModels = lib.mapAttrs (id: model: [id] ++ lib.optional (model ? canonical_id) model.canonical_id) extracted;
  # Full extracted offers supply defaults; consumers choose their own model subsets.
  catalog = {
    models = identities;
    vendors.opencode-go.models = builtins.attrNames extracted;
  };
  # OpenCode Go serves each catalog model on one native API. Each lands on
  # that API only, so CPA translates every other protocol itself. A function
  # of the catalog (`opencodeGo.models`) so checks can feed it malformed ones.
  opencodeGo = models: let
    # Gemini's generate-content has no API here; OpenCode serves every Go
    # text model on chat completions too, so it goes on chat.
    apiOf = {
      chat-completions = "chat";
      generate-content = "chat";
      messages = "anthropic";
      responses = "responses";
    };
    placed = lib.mapAttrsToList (id: entry: let
      natives = builtins.attrNames entry.api;
      native = lib.head natives;
    in
      if lib.length natives != 1
      then throw "cliproxyapi opencode-go: catalog model `${id}` has ${toString (lib.length natives)} native APIs; expected exactly one."
      else if !(apiOf ? ${native})
      then throw "cliproxyapi opencode-go: catalog model `${id}` has unknown native API `${native}`."
      else if !(entry.api.${native} ? base_url)
      then throw "cliproxyapi opencode-go: catalog model `${id}` has no base_url for native API `${native}`."
      else {
        inherit id native;
        api = apiOf.${native};
        inherit (entry.api.${native}) base_url;
      })
    models;
    onApi = api: lib.filter (model: model.api == api) placed;
    # The base URL comes from the API's own native models; the exception's
    # URL is another protocol's. CPA's claude executor appends
    # /v1/messages, the codex executor /responses, openai-compatibility
    # /chat/completions.
    baseUrl = api: let
      urls = lib.unique (map (model: model.base_url) (lib.filter (model: model.native != "generate-content") (onApi api)));
      url = lib.head urls;
    in
      if lib.length urls != 1
      then throw "cliproxyapi opencode-go: API `${api}` has base URLs ${builtins.toJSON urls} in the catalog; expected exactly one."
      else if api != "anthropic"
      then url
      else if lib.hasSuffix "/v1" url
      then lib.removeSuffix "/v1" url
      else throw "cliproxyapi opencode-go: messages base URL `${url}` does not end in /v1, which CPA's claude executor appends.";
  in {
    apis = lib.genAttrs (lib.unique (map (model: model.api) placed)) (api: {
      base-url = baseUrl api;
      models = map (model: model.id) (onApi api);
    });
    codexShellArgCleanup = false;
    # Go refuses a request without a session ID (HTTP 400 MissingSessionID);
    # CPA expands `$CPA-SESSION-ID` in credential headers to its own session
    # identifier (internal/util/header_helpers.go).
    headers.x-opencode-session = "$CPA-SESSION-ID";
    models = null;
    toolAliases = {};
  };
in {
  # Merged identities select vendor metadata; no transport facts leave this owner.
  construct = servedModels: merged:
    opencodeGo (lib.listToAttrs (map (id: let
      spellings = servedModels.${id} or [];
      upstream = lib.findFirst (name: lib.elem name spellings || lib.elem (extracted.${name}.canonical_id or null) spellings) null (builtins.attrNames extracted);
    in
      if upstream == null
      then throw "cliproxyapi opencode-go: catalog model `${id}` has unknown served ids ${builtins.toJSON spellings}; no extracted transport metadata."
      else lib.nameValuePair upstream extracted.${upstream})
    merged.vendors.opencode-go.models));
  # Static definitions are read by modules/catalog.nix and standalone construction.
  inherit catalog servedModels;
  # checks/catalog.nix supplies synthetic catalogs to exercise placement refusals.
  inherit opencodeGo;
}
