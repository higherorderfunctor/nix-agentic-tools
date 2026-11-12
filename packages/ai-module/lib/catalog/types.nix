# Static model identities and vendor offers, so owners share typed facts without routing policy.
{lib}: let
  # Use ordinary module fields so independent owners merge at each leaf.
  inherit (lib) mkOption types;
  # Model identifiers and aliases are exact, nonempty strings.
  names = types.listOf types.nonEmptyStr;
in {
  # An unknown maker is valid for a configured finite-only identity.
  model = types.submodule {
    options = {
      aliases = mkOption {
        type = types.attrsOf names;
        default = {};
        description = "Exact vendor spellings of this canonical model.";
      };
      maker = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Model maker, independently of its serving vendor; null is unknown.";
      };
      source = mkOption {
        type = types.nonEmptyListOf types.nonEmptyStr;
        description = "Evidence for this identity; independent owners contribute lists at equal priority.";
      };
    };
  };
  # The enclosing option checks the merged offer kind, including split definitions.
  vendor = types.submodule {
    options = {
      maker = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Serve every catalog model of this maker, including later additions.";
      };
      models = mkOption {
        type = types.nullOr names;
        default = null;
        description = "Finite canonical model ids served by this vendor; exclusive with maker.";
      };
    };
  };
}
