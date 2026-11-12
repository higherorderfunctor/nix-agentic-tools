{lib}: let
  inherit (lib) mkOption types;
  names = types.listOf types.nonEmptyStr;
  option = type: default: description: mkOption {inherit type default description;};
in {
  model = types.submodule {
    options = {
      aliases = option (types.attrsOf names) {} "Exact provider spellings of this canonical model.";
      maker = option (types.nullOr types.nonEmptyStr) null "Model maker, independently of its serving provider; null is unknown.";
      source = mkOption {
        type = types.nonEmptyStr;
        description = "Extracted or configured evidence for this identity.";
      };
    };
  };
  pool = types.submodule {
    options = {
      credentials = option (types.attrsOf (types.submodule {
        options = {
          auth = mkOption {type = types.enum ["apiKey" "oauth"];};
          binding = mkOption {
            type = types.nonEmptyStr;
            description = "Local instance/credential reference, never a secret value.";
          };
        };
      })) {} "Credentials spending this one budget.";
      models = option names [] "Finite API-key offers, resolved to canonical identities.";
      providerCatalogs = option names [] "Open OAuth provider catalogs, including future registered models.";
      usage = option (types.attrsOf (types.submodule {
        options = {
          adapter = mkOption {
            type = types.enum ["anthropic-spend" "claude-subscription" "codex-subscription" "opencode-go" "zai"];
            description = "Existing Reader observation adapter for this billing kind.";
          };
          runtime = mkOption {
            type = types.enum ["claude" "codex" "kimchi" "kiro"];
            description = "Runtime owning the registered usage technique.";
          };
          technique = mkOption {
            type = types.nonEmptyStr;
            description = "Enabled usage technique key; transport remains at its existing owner.";
          };
        };
      })) {} "One adapter and runtime-qualified technique per allowance billing kind, keyed by subscription or metered.";
    };
  };
  provider = types.submodule {
    options.maker = mkOption {
      type = types.nonEmptyStr;
      description = "Maker whose models belong to this provider's open catalog.";
    };
  };
  runtime = types.submodule {
    options.pools = option names [] "Only the pools reachable from this runtime; external delegates use their own reach.";
  };
}
