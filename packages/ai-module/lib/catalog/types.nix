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
