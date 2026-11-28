{
  config,
  lib,
  ...
}: {
  options.facetMock.activate = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable configuration-dependent registry controls.";
  };
  options.facetMock.entries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        owner = lib.mkOption {type = lib.types.str;};
        payload = lib.mkOption {type = lib.types.str;};
        source = lib.mkOption {type = lib.types.str;};
      };
    });
    default = {};
    description = "Native module values contributed by tracked mock facets.";
  };

  config.facetMock.entries =
    {
      # The unconditional claim isolates ordinary root/owner collisions.
      root-policy = {
        owner = "root";
        payload = "root-policy";
        source = toString ./registry.nix;
      };
    }
    # Inspecting only the winning value would hide a competing owner when
    # another module activates this forced root claim.
    // lib.optionalAttrs config.facetMock.activate {
      conditional-root = lib.mkForce {
        owner = "root";
        payload = "conditional-root";
        source = toString ./registry.nix;
      };
    };
}
