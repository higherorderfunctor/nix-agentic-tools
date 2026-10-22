# `ai.cliproxyapi.instances.<n>.providers`: named upstream API-key providers.
# A provider holds one upstream key, its models, and the base URL of each API
# it serves. The instance lowers each API into the `api-keys` family CPA
# serves that API from, and a runtime that enables the provider gets one
# allowlist rule naming that block's base URL, so two providers on one
# protocol stay apart (docs/cliproxyapi-key-allowlist.md, base-urls).
#
# `apis` is the one table of API → CPA family. A runtime names the API it
# speaks on its own record (`proxyApi`), never here.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../../lib/redact {inherit lib;};

  # family: the `api-keys.<family>` block; provider: the credential provider
  # CPA records for it (internal/watcher/synthesizer/config.go: claude 187,
  # codex 271, openai-compatibility 345 via OpenAICompatibleProviderKey of the
  # lower-cased group name); key: fields the provider's key entry adds.
  #
  # OpenAICompatibleProviderKey (internal/util/provider.go:18-26) keeps
  # `openai-compatibility` and a name already carrying the prefix, and
  # prefixes any other. Names are ASCII words (../modules/instances.nix), so
  # Nix's toLower is Go's ToLower here and there is nothing to trim.
  apis = {
    anthropic = {
      family = "claude";
      key = {};
      provider = _: "claude";
    };
    chat = {
      family = "openai-compatibility";
      key = {};
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

  # CPA trims a base URL with Go's strings.TrimSpace, which strips Unicode
  # spaces (no-break space, form feed, vertical tab, ...) that Nix's trim
  # keeps, then compares exactly. Printable ASCII only means there is nothing
  # to trim and no two spellings of one URL, so the block, its rule and the
  # shared-URL check in ../modules/instances.nix all compare the same string.
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
                  description = "The upstream's base URL for this API, written to the block's `base-url` and to each rule that reaches it.";
                };
              });
              default = null;
              description = "Serve the provider's models on the ${api} API, as an `api-keys.${entry.family}` block.";
            })
          apis;
        };
        default = {};
        description = "The APIs this provider serves, each with its base URL.";
      };
      key = mkOption {
        type = redact.types.redacted;
        description = "The upstream API key, as a redact reference; it is rendered at start and never reaches the Nix store.";
      };
      models = mkOption {
        type = types.nonEmptyListOf types.str;
        example = ["glm-5.3"];
        description = "The models the provider serves, registered on each of its APIs.";
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
          keys = [({api-key = provider.key;} // apis.${api}.key)];
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
