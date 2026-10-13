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
          exe = lib.mkOption {
            type = lib.types.str;
            description = "Absolute guest executable path, usually lib.getExe or lib.getExe' applied to a package.";
          };
          outName = lib.mkOption {
            default = name;
            type = lib.types.str;
            description = "Host wrapper executable name.";
          };
        };
      }));
    };
  };
}
