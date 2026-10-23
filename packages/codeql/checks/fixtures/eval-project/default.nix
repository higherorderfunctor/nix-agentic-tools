{lib}: let
  enabledSubmodule = lib.types.submodule {
    options.enabled = lib.mkOption {type = lib.types.bool;};
    config.enabled = lib.mkDefault false;
  };
  modules = [
    ({
      fixtureValue,
      lib,
      options,
      ...
    }: {
      disabledModules = ["disabled.nix"];
      imports = [./disabled.nix];
      options = {
        direct = lib.mkOption {type = enabledSubmodule;};
        enabled = lib.mkOption {type = lib.types.bool;};
        forwarded = lib.mkOption {type = lib.types.bool;};
        groups = lib.mkOption {type = lib.types.attrsOf (lib.types.attrsOf enabledSubmodule);};
        inactive = lib.mkOption {type = lib.types.str;};
        instances = lib.mkOption {
          default = {};
          type = lib.types.attrsOf enabledSubmodule;
        };
        listInstances = lib.mkOption {type = lib.types.listOf enabledSubmodule;};
        mixed = lib.mkOption {type = lib.types.attrsOf (lib.types.listOf enabledSubmodule);};
        renamed = lib.mkOption {type = lib.types.bool;};
        seed = lib.mkOption {
          default = false;
          type = lib.types.bool;
        };
        structured = lib.mkOption {type = lib.types.attrs;};
        tagged = lib.mkOption {type = lib.types.attrs;};
        throwing = lib.mkOption {type = lib.types.bool;};
      };
      config = {
        enabled = lib.mkDefault fixtureValue;
        forwarded = lib.modules.mkAliasAndWrapDefsWithPriority lib.id options.seed;
        inactive = lib.mkIf false (throw "inactive contents must not be evaluated");
        structured = lib.mkDefault {child = throw "losing set children must remain lazy";};
        tagged = {
          _type = "flake";
          foo = throw "tagged set children must remain lazy";
        };
        throwing = lib.mkDefault (throw "losing contents must not fail the dump");
      };
    })
    {
      _file = "synthetic-module";
      options = builtins.mapAttrs (_: _:
        lib.mkOption {
          default = false;
          type = lib.types.bool;
        }) (builtins.fromJSON ''{"synthetic":null}'');
    }
    (lib.mkAliasOptionModule ["old"] ["renamed"])
    {
      direct.enabled = true;
      enabled = true;
      groups.a.b.enabled = true;
      instances.first.enabled = true;
      listInstances = [{enabled = true;}];
      mixed.a = [{enabled = true;}];
      old = true;
      structured.child = true;
      throwing = true;
    }
  ];
in {
  inherit lib modules;
  result = lib.evalModules {
    inherit modules;
    specialArgs = {
      fixtureValue = false;
      modulesPath = ./.;
    };
  };
}
