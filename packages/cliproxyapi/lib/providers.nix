# One API → CPA credential-family table for named upstream API-key credentials.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../../lib/redact {inherit lib;};
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  vendors.z-ai = facts.get (facts.load {dir = ../extracted;}).aggregate "zAi";

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

  # Alias is printable ASCII without spaces, so CPA's TrimSpace is a no-op.
  modelType = types.coercedTo types.str (name: {inherit name;}) (types.submodule {
    options = {
      alias = mkOption {
        type = types.nullOr (types.strMatching "[!-~]+");
        default = null;
        description = "Client-visible name CPA lists and routes for this model (`models[].alias`); a request for it is sent upstream as `name`. Unset lists `name`.";
      };
      name = mkOption {
        type = types.str;
        description = "Upstream model name.";
      };
    };
  });

  apiKeyType = types.submodule {
    options = {
      apis = mkOption {
        type = types.submodule {
          options = lib.mapAttrs (api: entry:
            mkOption {
              type = types.nullOr (types.submodule {
                options.base-url = mkOption {
                  type = baseUrlType;
                  description = "The upstream base URL for this API.";
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
      key = mkOption {
        type = redact.types.redacted;
        description = "The upstream key, as a redact reference.";
      };
      models = mkOption {
        type = types.nonEmptyListOf modelType;
        example = [
          "glm-5.3"
          {
            name = "glm-5.3";
            alias = "claude-opus-5-5";
          }
        ];
        description = "Models served on each API: a plain upstream name, or `{name; alias;}` to serve `name` under the client-visible `alias`.";
      };
      priority = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "CPA credential priority on every served API. Higher values win among available credentials, subject to CPA transport preference and session affinity; unset uses CPA's default of 0. Negative values permit fallback behind default-priority OAuth logins.";
      };
    };
  };

  served = provider: lib.filterAttrs (_: value: value != null) provider.apis;

  # Client-visible name: CPA lists alias when set, else name
  # (sdk/cliproxy/service_models.go:813-816).
  modelName = model:
    if model.alias != null
    then model.alias
    else model.name;
  visibleModels = apiKey: map modelName apiKey.models;

  # One upstream credential's blocks: { <family> = [block]; }.
  blocks = name: provider:
    lib.mapAttrs' (api: value:
      lib.nameValuePair apis.${api}.family [
        ({
            inherit name;
            inherit (value) base-url;
            keys = [({api-key = provider.key;} // (apis.${api}.key or {}))];
            models =
              map
              (model:
                {inherit (model) name;}
                // lib.optionalAttrs (model.alias != null) {inherit (model) alias;})
              provider.models;
          }
          // lib.optionalAttrs (provider.priority != null) {inherit (provider) priority;})
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
        description = "Built-in vendor defaults for this API-key upstream credential. z-ai uses z.ai's standard API; a Coding Plan may require overriding the chat base URL. Every API and model default can be overridden; supply apiKey.key as a redact reference.";
      };
    };
    config = lib.mkIf (config.vendor != null) {
      apiKey = {
        apis = lib.mapAttrs (_: lib.mkDefault) vendors.${config.vendor}.apis;
        models = lib.mkDefault vendors.${config.vendor}.models;
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
    else {rule = rule choice.credential credential.apiKey api;};
in {
  inherit apiKeys apis clientKeyType credentialType route rule served visibleModels;
  lower = providers: lib.zipAttrsWith (_: lib.concatLists) (lib.mapAttrsToList blocks providers);
}
