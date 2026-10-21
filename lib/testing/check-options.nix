{lib, ...}: {
  options = {
    checks = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.package;
      default = {};
      description = "Derivation checks contributed by package and workspace modules.";
    };
    testing = {
      homeManagerAiPackages = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        default = {};
        description = "Small owner-provided packages for Home Manager wrapper tests.";
      };
      moduleProbes = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [];
        description = "Owner configurations that activate package pool contributions.";
      };
    };
  };
}
