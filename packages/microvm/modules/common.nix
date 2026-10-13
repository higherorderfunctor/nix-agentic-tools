{
  config,
  lib,
  ...
}: let
  names = map (sandbox: sandbox.outName) (builtins.attrValues config.ai.sandboxes);
in {
  config.assertions = [
    {
      assertion = builtins.length names == builtins.length (lib.unique names);
      message = "ai.sandboxes: each outName must be unique.";
    }
  ];
  options.ai = {
    sandboxes = lib.mkOption {
      default = {};
      description = "Fresh Linux KVM guests running one package executable on the serial console.";
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          binName = lib.mkOption {
            type = lib.types.str;
            description = "Executable name in pkg/bin.";
          };
          outName = lib.mkOption {
            default = name;
            type = lib.types.str;
            description = "Host wrapper executable name.";
          };
          pkg = lib.mkOption {
            type = lib.types.package;
            description = "Package to run in the guest.";
          };
        };
      }));
    };
  };
}
