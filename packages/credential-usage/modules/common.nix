# Declares `ai.credentialUsage.readers.<id>`, the registry that fill owners
# contribute their Readers to. Home Manager and devenv import this file, and
# `lib/readers.nix` evaluates it for callers that build outside a module tree.
{lib, ...}: {
  options.ai.credentialUsage.readers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          description = "Packaged Reader command. It prints one versioned usage envelope per account.";
        };
        transports = lib.mkOption {
          type = lib.types.nonEmptyListOf (lib.types.enum ["direct" "cpa"]);
          description = "Transports this Reader sends requests through: direct with a local login, cpa through a CLIProxyAPI instance.";
        };
        endpoint = lib.mkOption {
          type = lib.types.str;
          description = "Vendor origin the Reader's requests target.";
        };
      };
    });
    default = {};
    description = "Usage Readers by id. Fill owners contribute their command at default priority; an ordinary definition selects another package.";
  };
}
