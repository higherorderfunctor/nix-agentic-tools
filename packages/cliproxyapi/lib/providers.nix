# One API → CPA credential-family table for named upstream providers.
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

  providerType = types.submodule {
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
        description = "The APIs this provider serves, each with its base URL.";
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

  # One provider's blocks: { <family> = [block]; }.
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

  # The rule that reaches provider `name`'s block for `api`, and only it.
  rule = name: provider: api: {
    base-urls = [provider.apis.${api}.base-url];
    kind = "apikey";
    provider = apis.${api}.provider name;
  };
in {
  inherit apis providerType rule served;
  # settings.api-keys for every provider, in name order.
  lower = providers: lib.zipAttrsWith (_: lib.concatLists) (lib.mapAttrsToList blocks providers);
}
