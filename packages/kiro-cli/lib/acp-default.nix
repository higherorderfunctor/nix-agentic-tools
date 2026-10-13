# ACP does not consult persisted chat.agentEngine. Supply only a declared
# default at the existing build launcher; explicit argv remains authoritative.
{lib}: engine: valueFlags: let
  argv = import ../../../lib/idempotentFlags.nix {inherit lib;};
in
  lib.optionalString (engine != null) (''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
    ''
    + argv.gateOnSubcommand {
      subcommands = ["acp"];
      inherit valueFlags;
    } ''
      ${argv.optionValueBlock {
        flag = "--agent-engine";
        var = "nat_engine";
      }}
      for nat_arg in "$@"; do
        case "$nat_arg" in
          --) break ;;
          --agent-engine|--v1|--v2|--v3) nat_engine=explicit ;;
        esac
      done
      if [ -z "$nat_engine" ]; then
        nat_default=(${lib.escapeShellArg "--agent-engine=${engine}"})
        nat_args=()
        for nat_arg in "$@"; do
          if [ "$nat_arg" = -- ]; then
            nat_args+=("''${nat_default[@]}")
            nat_default=()
          fi
          nat_args+=("$nat_arg")
        done
        set -- "''${nat_args[@]}" "''${nat_default[@]}"
      fi
    '')
