# Declares `ai.credentialUsage.readers.<id>`, the registry that fill owners
# contribute their Readers to. Home Manager and devenv import this file, and
# `lib/readers.nix` evaluates it for callers that build outside a module tree.
{lib, ...}: {
  options.ai.credentialUsage.readers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        cpa = lib.mkOption {
          default = null;
          description = "CPA binding for the registered Reader command. Null keeps the Reader's normal credential selection.";
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              endpoint = lib.mkOption {
                type = lib.types.strMatching "https?://[^/@?#[:space:]]+(/[^@?#[:space:]]*)?";
                description = "Public management endpoint of the selected CPA instance.";
              };
              managementKeyFile = lib.mkOption {
                type = lib.types.addCheck (lib.types.strMatching "/.+") (path: !(builtins.hasContext path));
                description = "Absolute runtime filename containing the management key.";
              };
              pin = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "CPA auth index to select from the Reader's eligible accounts.";
              };
              policy = {
                retries = lib.mkOption {
                  type = lib.types.ints.unsigned;
                  default = 0;
                  description = "Network retries per management request.";
                };
                timeout = lib.mkOption {
                  type = lib.types.numbers.positive;
                  default = 75;
                  description = "HTTP timeout per management request in seconds.";
                };
              };
            };
          });
        };
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
          description = "Informational vendor origin fixed by the fill. Configure cpa.endpoint to select the management endpoint.";
        };
      };
    });
    default = {};
    description = "Usage Readers by id. Fill owners contribute their command at default priority; an ordinary definition selects another package.";
  };
}
