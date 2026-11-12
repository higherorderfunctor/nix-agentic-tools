# OpenCode Go defaults and native-API placement, shared by credentials and synthetic checks.
{lib}: let
  # Read the measured Go catalog where its vendor defaults are built.
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  # Use CPA's aggregate so missing or divergent vendor facts fail at their source.
  fact = facts.get (facts.load {dir = ../../extracted;}).aggregate;
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
    # Subscriptions the operator already routes through CPA serve these
    # families: Claude OAuth (claude-*), z.ai, shipped here as
    # `vendor = "z-ai"` (glm-*), and Codex OAuth (gpt-*). OpenCode would only
    # duplicate them, so the defaults leave them out and
    # ../../modules/instances.nix refuses any a definition adds.
    refuses = model: lib.any (prefix: lib.hasPrefix prefix (lib.toLower model)) ["claude-" "glm-" "gpt-"];
    catalog = lib.filterAttrs (id: _: !(refuses id)) models;
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
    catalog;
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
    refusal = "OpenCode Go may not serve claude-*, glm-* or gpt-* models; the Claude OAuth, z.ai and Codex OAuth credentials serve them.";
    inherit refuses;
    toolAliases = {};
  };
in {
  # Production credentials use the measured catalog through the same placement function.
  defaults = opencodeGo (fact "opencodeGo").models;
  # module-eval.nix supplies synthetic catalogs to exercise placement refusals.
  inherit opencodeGo;
}
