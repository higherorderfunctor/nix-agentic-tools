# Give the routing helper a standalone Reader with the configured Claude CLI on PATH.
{
  pkgs,
  python-stack,
  claude ? pkgs.ai.claude-code,
  cpa ? null,
  direct ? null,
}: let
  publicPolicy = binding:
    builtins.intersectAttrs {
      retries = null;
      timeout = null;
    } (binding.policy or {});
  moduleArgs = {inherit pkgs python-stack;};
  claudeModule = (import ./default.nix).ai.claude-code.pythonModule moduleArgs;
  cpaModule = (import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule moduleArgs;
  credentialModule = (import ../../credential-usage/lib/default.nix).ai.credential-usage.pythonModule moduleArgs;
  python = python-stack.withPackages (ps: [ps.pydantic ps.urllib3 claudeModule cpaModule credentialModule]);
in
  (import ../../../lib/strict-shell-application.nix pkgs) {
    name = "claude-usage";
    runtimeInputs = [claude];
    text =
      pkgs.lib.optionalString (cpa != null) ''
        export CLAUDE_USAGE_CPA_BINDING=${pkgs.lib.escapeShellArg (builtins.toJSON {
          inherit (cpa) endpoint managementKeyFile;
          pin = cpa.pin or null;
          policy = publicPolicy cpa;
        })}
      ''
      + pkgs.lib.optionalString (direct != null) ''
        export CLAUDE_USAGE_DIRECT_POLICY=${pkgs.lib.escapeShellArg (builtins.toJSON (publicPolicy direct))}
      ''
      + ''exec ${python}/bin/python3 -I -m claude_code.usage.cli "$@"'';
  }
