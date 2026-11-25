# The registered Claude Reader, run as the installed command, sends its pair's requests and prints its pair's results.
{pkgs, ...}: let
  inherit (pkgs) lib;
  inherit (pkgs.ai.generic) python-stack;
  credentialUsage = (import ../../credential-usage/lib/default.nix).ai.credential-usage;
  inherit ((import ../lib/default.nix).ai.claude-code) usageModule;
  reader =
    (credentialUsage.mergeReaders {inherit pkgs lib;} {
      contributions = [usageModule];
    }).claude.package;
  python = python-stack.withPackages (ps: [
    ps.pydantic
    ps.urllib3
    (credentialUsage.pythonModule {inherit pkgs python-stack;})
  ]);
in {
  checks.claude-code-usage-command =
    pkgs.runCommand "claude-code-usage-command" {
      nativeBuildInputs = [pkgs.bash python];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 -I -B ${../../credential-usage/checks/conformance}/standalone.py ${../usage/cases} ${lib.getExe reader}
      touch "$out"
    '';
}
