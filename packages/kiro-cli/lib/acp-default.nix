# ACP ignores persisted engine settings; bridge them in the existing payload
# launchers, preserving native argv precedence and cwd-local repository scope.
{
  jq,
  lib,
}: valueFlags: let
  argv = import ../../../lib/idempotentFlags.nix {inherit lib;};
in
  ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    nat_additions=()
  ''
  + argv.gateOnSubcommand {
    subcommands = ["acp"];
    inherit valueFlags;
  } ''
    ${argv.optionValueBlock {
      aliases = {
        "--v1" = "v1";
        "--v2" = "v2";
        "--v3" = "v3";
      };
      flag = "--agent-engine";
      inherit valueFlags;
      var = "nat_engine";
    }}
    if [ "$nat_engine_seen" = 0 ]; then
      for nat_settings in "''${KIRO_HOME:-$HOME/.kiro}/settings/cli.json" ./.kiro/settings/cli.json; do
        if [ -f "$nat_settings" ]; then
          nat_value="$(${jq}/bin/jq -r 'if has("chat.agentEngine") then .["chat.agentEngine"] // "" else empty end' "$nat_settings")"
          if ${jq}/bin/jq -e 'has("chat.agentEngine")' "$nat_settings" >/dev/null; then
            nat_engine="$nat_value"
          fi
        fi
      done
      if [ -n "$nat_engine" ]; then
        nat_additions+=(--agent-engine "$nat_engine")
      fi
    fi
  ''
  + "\n"
  + ''
    if [ -n "''${NAT_KIRO_TRUST_TOOLS:-}" ]; then
      ${argv.optionValueBlock {
      flag = "--trust-tools";
      inherit valueFlags;
      var = "nat_trust";
    }}
      if [ "$nat_trust_seen" = 0 ] && { [ "$nat_sub" = chat ] || { [ "$nat_sub" = acp ] && [ "$nat_engine" != v3 ]; }; }; then
        nat_additions+=("--trust-tools=$NAT_KIRO_TRUST_TOOLS")
      fi
    fi
    unset NAT_KIRO_TRUST_TOOLS
    if [ "''${#nat_additions[@]}" -gt 0 ]; then
      ${argv.appendArgsBlock {
      args = ''"''${nat_additions[@]}"'';
      valueFlags = valueFlags ++ ["--agent-engine" "--auth-method" "--trust-tools"];
    }}
    fi
  ''
