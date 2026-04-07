# Core devshell module — defines the top-level options and produces
# the final mkShell derivation from evaluated config.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Packages available in the devshell.";
    };

    shellHook = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Shell hook executed on shell entry.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "agentic-shell";
      description = "Name of the devshell derivation.";
    };

    shell = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The final mkShell derivation. Do not set directly.";
    };
  };

  config.shell = pkgs.mkShell {
    inherit (config) name packages shellHook;
  };
}
