# The one interpreter the Claude usage Reader runs and type-checks in: pydantic,
# urllib3, and the Reader, CPA and credential-usage modules.
{
  pkgs,
  python-stack,
}: let
  moduleArgs = {inherit pkgs python-stack;};
  claudeModule = (import ./default.nix).ai.claude-code.pythonModule moduleArgs;
  cpaModule = (import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule moduleArgs;
  credentialModule = (import ../../credential-usage/lib/default.nix).ai.credential-usage.pythonModule moduleArgs;
in
  python-stack.withPackages (ps: [ps.pydantic ps.urllib3 claudeModule cpaModule credentialModule])
