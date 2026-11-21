# Module and manual skill builders share the credential Reader registration schema.
{lib}: let
  inherit (import ./vocabulary.nix) supportedRuntimes;
  usage = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule {
      options = {
        runtime = lib.mkOption {
          type = lib.types.enum supportedRuntimes;
          description = "Enabled runtime whose usage technique reads this pool.";
        };
        technique = lib.mkOption {
          type = lib.types.str;
          description = "Enabled usage technique with a non-empty command for this pool.";
        };
      };
    });
    default = null;
    description = "Canonical usage reader for this budget, resolved from the runtime's techniques.";
  };
  inherit (lib) mkOption types;
in {
  inherit usage;
  credentialUsage = mkOption {
    default = {};
    description = "Reader registrations by CPA instance/credential.";
    type = types.attrsOf (types.submodule {
      options = {
        inherit usage;
        limits = mkOption {
          default = {};
          description = "Allowance limits supplied by this credential's Reader.";
          type = types.attrsOf (types.submodule {
            options = {
              capacity = mkOption {
                type = types.numbers.positive;
                description = "Capacity in the Reader's native unit.";
              };
              models = mkOption {
                type = types.nullOr (types.nonEmptyListOf types.nonEmptyStr);
                default = null;
                description = "Canonical model IDs covered by this limit. Null covers every offer on this credential.";
              };
              role = mkOption {
                type = types.enum ["gate" "pace"];
                description = "Whether this window gates or paces use.";
              };
              window = mkOption {
                type = types.nonEmptyStr;
                description = "Exact Reader window name.";
              };
            };
          });
        };
        pin = mkOption {
          type = types.nullOr types.nonEmptyStr;
          default = null;
          description = "CPA auth index. Null asks the Reader to discover one eligible account.";
        };
        readerPool = mkOption {
          type = types.nonEmptyStr;
          description = "Expected pool label in the Reader response.";
        };
        transport = {
          retries = mkOption {
            type = types.ints.unsigned;
            default = 0;
            description = "Network retries per HTTP operation.";
          };
          timeout = mkOption {
            type = types.numbers.positive;
            default = 75;
            description = "HTTP timeout in seconds.";
          };
        };
      };
    });
  };
}
