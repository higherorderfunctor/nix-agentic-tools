# The CPA transport binds one credential and forwards through api-call against
# recorded replies, direct HTTP keeps its token on one origin, and the transport
# type-checks strictly beside the generic transport it shares.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  credentialUsageModule = (import ../../credential-usage/lib/default.nix).ai.credential-usage.pythonModule {inherit pkgs python-stack;};
  cpaUsageModule = (import ../lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule {inherit pkgs python-stack;};
  usagePython = python-stack.withPackages (ps: [ps.pydantic ps.urllib3 credentialUsageModule cpaUsageModule]);
  strict = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  checks.cliproxyapi-usage-transport = pkgs.runCommand "cliproxyapi-usage-transport" {nativeBuildInputs = [usagePython];} ''
    ${strict}
    python3 -I -B ${./transport}/test_transport.py
    touch "$out"
  '';
  checks.cliproxyapi-usage-types = pkgs.runCommand "cliproxyapi-usage-types" {nativeBuildInputs = [pkgs.pyright usagePython];} ''
    ${strict}
    pyright --project ${../usage} --pythonpath "$(command -v python3)"
    touch "$out"
  '';
}
