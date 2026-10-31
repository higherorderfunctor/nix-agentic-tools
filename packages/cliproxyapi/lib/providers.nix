# One API → CPA credential-family table for named upstream API-key credentials.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../../lib/redact {inherit lib;};
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  fact = facts.get (facts.load {dir = ../extracted;}).aggregate;
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
    # ../modules/instances.nix refuses any a definition adds.
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
    models = null;
    refusal = "OpenCode Go may not serve claude-*, glm-* or gpt-* models; the Claude OAuth, z.ai and Codex OAuth credentials serve them.";
    inherit refuses;
    toolAliases = {};
  };
  vendors = {
    opencode-go = opencodeGo (fact "opencodeGo").models;
    z-ai =
      fact "zAi"
      // {
        codexShellArgCleanup = true;
        toolAliases.ToolSearch = "ToolSearch_";
      };
  };

  # CPA's OpenAICompatibleProviderKey preserves one exact name and one prefix.
  # Provider names are ASCII (../modules/instances.nix), so toLower agrees.
  apis = {
    anthropic = {
      family = "claude";
      provider = _: "claude";
    };
    chat = {
      family = "openai-compatibility";
      provider = name: let
        lower = lib.toLower name;
        prefix = "openai-compatible-";
      in
        if lower == "openai-compatibility" || lib.hasPrefix prefix lower
        then lower
        else prefix + lower;
    };
    # The codex executor's cloaking dresses requests as the Codex CLI for
    # ChatGPT's backend; a third-party Responses endpoint wants them as sent.
    responses = {
      family = "codex";
      key.disable-codex-cloaking = true;
      provider = _: "codex";
    };
  };

  # Printable ASCII makes CPA's Unicode TrimSpace a no-op, so the rule and
  # shared-URL check in ../modules/instances.nix compare the same string.
  baseUrlType = types.strMatching "https?://[!-~]+";
  # CPA trims model names before registering them
  # (sdk/cliproxy/service_models.go); printable-ASCII edges make that trim a
  # no-op, so a vendor's refusal sees the name CPA serves. The interior is free.
  modelType = types.strMatching "[!-~](.*[!-~])?" // {description = "model name whose first and last characters are printable ASCII other than space";};

  apiKeyType = types.submodule {
    options = {
      apis = mkOption {
        type = types.submodule {
          options = lib.mapAttrs (api: entry:
            mkOption {
              type = types.nullOr (types.submodule {
                options = {
                  base-url = mkOption {
                    type = baseUrlType;
                    description = "The upstream base URL for this API.";
                  };
                  models = mkOption {
                    type = types.nullOr (types.nonEmptyListOf modelType);
                    default = null;
                    example = ["glm-5.3"];
                    description = "Models served on this API, replacing the credential's `models`.";
                  };
                };
              });
              default = null;
              description = "Serve ${api} through `api-keys.${entry.family}`.";
            })
          apis;
        };
        default = {};
        description = "The APIs this upstream credential serves, each with its base URL.";
      };
      codexShellArgCleanup = mkOption {
        type = types.bool;
        default = false;
        description = "Remove redundant approval fields from exec_command and shell_command function calls returned through the chat API. Explicit escalation requests keep their justification.";
      };
      key = mkOption {
        type = redact.types.redacted;
        description = "The upstream key, as a redact reference.";
      };
      models = mkOption {
        type = types.nullOr (types.nonEmptyListOf modelType);
        default = null;
        example = ["glm-5.3"];
        description = "Models served on each API that sets no `models` of its own. Every served API needs one of the two.";
      };
      priority = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "CPA credential priority on every served API. Higher values win among available credentials, subject to CPA transport preference and session affinity; unset uses CPA's default of 0. Negative values permit fallback behind default-priority OAuth logins.";
      };
      toolAliases = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Client-to-upstream tool names on the Anthropic API. Names must contain 1-64 letters, digits, underscores or hyphens; upstream names must be unique and may not name another alias source. An empty map disables aliases.";
      };
    };
  };

  served = provider: lib.filterAttrs (_: value: value != null) provider.apis;
  # The models one served API offers; null when neither level declares any,
  # which ../modules/instances.nix refuses.
  modelsOf = provider: api: lib.defaultTo provider.models provider.apis.${api}.models;

  # One upstream credential's blocks: { <family> = [block]; }.
  blocks = name: provider:
    lib.mapAttrs' (api: value:
      lib.nameValuePair apis.${api}.family [
        ({
            inherit name;
            inherit (value) base-url;
            keys = [({api-key = provider.key;} // (apis.${api}.key or {}))];
            models = map (model: {name = model;}) (lib.defaultTo [] (modelsOf provider api));
          }
          // lib.optionalAttrs (provider.priority != null) {inherit (provider) priority;}
          // lib.optionalAttrs (api == "anthropic" && provider.toolAliases != {}) {tool-aliases = provider.toolAliases;}
          // lib.optionalAttrs (api == "chat" && provider.codexShellArgCleanup) {codex-shell-arg-cleanup = true;})
      ])
    (served provider);

  # The rule that reaches upstream credential `name`'s block for `api`, and only it.
  rule = name: provider: api: {
    base-urls = [provider.apis.${api}.base-url];
    kind = "apikey";
    provider = apis.${api}.provider name;
  };
  credentialType = types.submodule ({config, ...}: {
    options = {
      apiKey = mkOption {
        type = types.nullOr apiKeyType;
        default = null;
        description = "An API-key upstream credential declared in Nix, with its models and APIs.";
      };
      oauth = mkOption {
        type = types.nullOr (types.submodule {
          # OAuth priority belongs to CPA login-file metadata; declaring
          # oauth.priority here would accept a value no config field can apply.
          options = {
            account = mkOption {
              type = redact.types.redacted;
              description = "Exact account email as a redact reference. CPA matches OAuth logins by their trimmed account email.";
            };
            vendor = mkOption {
              type = types.strMatching "[a-z][a-z0-9-]*";
              description = "Vendor's CPA provider field, such as `claude` (Anthropic) or `codex` (OpenAI).";
            };
          };
        });
        default = null;
        description = "An OAuth upstream credential held in CPA's auth directory. Declare exactly one of oauth or apiKey.";
      };
      vendor = mkOption {
        type = types.nullOr (types.enum (builtins.attrNames vendors));
        default = null;
        description = "Built-in vendor defaults for this API-key upstream credential. z-ai uses z.ai's standard API; a Coding Plan may require overriding the chat base URL. opencode-go places each OpenCode Go catalog model on its native API, without claude-*, glm-* or gpt-* models, which it refuses. Every API and model default can be overridden; supply apiKey.key as a redact reference.";
      };
    };
    config = lib.mkIf (config.vendor != null) {
      apiKey = {
        apis = lib.mapAttrs (_: lib.mkDefault) vendors.${config.vendor}.apis;
        codexShellArgCleanup = lib.mkDefault vendors.${config.vendor}.codexShellArgCleanup;
        models = lib.mkDefault vendors.${config.vendor}.models;
        toolAliases = lib.mkDefault vendors.${config.vendor}.toolAliases;
      };
    };
  });
  clientKeyType = types.submodule {
    options = {
      key = mkOption {
        type = redact.types.redacted;
        description = "Client key the Harness presents to CPA, as a redact reference.";
      };
      routes = mkOption {
        type = types.nonEmptyListOf (types.submodule {
          options = {
            api = mkOption {
              type = types.nullOr (types.enum (builtins.attrNames apis));
              default = null;
              description = "API of the API-key upstream credential. Omit only for OAuth or an API-key credential serving one API. CPA translates Harness protocols; this can select chat for Codex CLI.";
            };
            credential = mkOption {
              type = types.str;
              description = "Name in this Instance's credentials. Routes preserve this list's order without promising CPA fallback order.";
            };
          };
        });
        description = "Ordered names of the only upstream credentials this client key may reach.";
      };
    };
  };
  apiKeys = instance: lib.mapAttrs (_: credential: credential.apiKey) (lib.filterAttrs (_: credential: credential.apiKey != null) instance.credentials);
  route = instance: path: choice: let
    credential = instance.credentials.${choice.credential} or null;
    available =
      if credential == null || credential.apiKey == null
      then []
      else builtins.attrNames (served credential.apiKey);
    api =
      if choice.api != null
      then choice.api
      else if lib.length available == 1
      then lib.head available
      else null;
  in
    if credential == null
    then {problem = "${path} names unknown upstream credential `${choice.credential}`.";}
    else if credential.oauth != null
    then
      if choice.api != null
      then {problem = "${path}: OAuth credential `${choice.credential}` does not select an API; remove api.";}
      else {
        rule = {
          provider = credential.oauth.vendor;
          kind = "oauth";
          accounts = [credential.oauth.account];
        };
      }
    else if api == null
    then {problem = "${path}: API-key credential `${choice.credential}` needs api because it does not serve exactly one API.";}
    else if !(lib.elem api available)
    then {problem = "${path}: upstream credential `${choice.credential}` does not serve API `${api}`.";}
    else {
      models = lib.defaultTo [] (modelsOf credential.apiKey api);
      rule = rule choice.credential credential.apiKey api;
    };
in {
  inherit apiKeys apis clientKeyType credentialType modelsOf opencodeGo route rule served vendors;
  lower = providers: lib.zipAttrsWith (_: lib.concatLists) (lib.mapAttrsToList blocks providers);
}
