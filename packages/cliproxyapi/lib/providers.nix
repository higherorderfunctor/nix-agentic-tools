# One API → CPA credential-family table for named upstream API-key credentials.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../../lib/redact {inherit lib;};

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
        type = types.nonEmptyListOf types.str;
        example = ["glm-5.3"];
        description = "Models served on each API.";
      };
    };
  };

  served = provider: lib.filterAttrs (_: value: value != null) provider.apis;

  # One upstream credential's blocks: { <family> = [block]; }.
  blocks = name: provider:
    lib.mapAttrs' (api: value:
      lib.nameValuePair apis.${api}.family [
        {
          inherit name;
          inherit (value) base-url;
          keys = [({api-key = provider.key;} // (apis.${api}.key or {}))];
          models = map (model: {name = model;}) provider.models;
        }
      ])
    (served provider);

  # The rule that reaches upstream credential `name`'s block for `api`, and only it.
  rule = name: provider: api: {
    base-urls = [provider.apis.${api}.base-url];
    kind = "apikey";
    provider = apis.${api}.provider name;
  };
  credentialType = types.submodule {
    options = {
      apiKey = mkOption {
        type = types.nullOr apiKeyType;
        default = null;
        description = "An API-key upstream credential declared in Nix, with its models and APIs.";
      };
      oauth = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            authFile = mkOption {
              type = types.strMatching "[^/[:space:]][^/]*\\.json";
              description = "Exact filename CPA wrote in `<stateDir>/auth`; list that directory after login. Re-login may change it.";
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
    };
  };
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
          ids = [credential.oauth.authFile];
        };
      }
    else if api == null
    then {problem = "${path}: API-key credential `${choice.credential}` needs api because it does not serve exactly one API.";}
    else if !(lib.elem api available)
    then {problem = "${path}: upstream credential `${choice.credential}` does not serve API `${api}`.";}
    else {rule = rule choice.credential credential.apiKey api;};
in {
  inherit apiKeys apis clientKeyType credentialType route rule served;
  lower = providers: lib.zipAttrsWith (_: lib.concatLists) (lib.mapAttrsToList blocks providers);
}
