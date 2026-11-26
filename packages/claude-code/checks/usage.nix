# The Claude usage Reader type-checks strictly against the envelope and the
# transports it imports, and its packaged command builds.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  moduleArgs = {inherit pkgs python-stack;};
  claudeModule = (import ../lib/default.nix).ai.claude-code.pythonModule moduleArgs;
  cpaModule = (import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule moduleArgs;
  credentialModule = (import ../../credential-usage/lib/default.nix).ai.credential-usage.pythonModule moduleArgs;
  python = python-stack.withPackages (ps: [ps.pydantic ps.urllib3 claudeModule cpaModule credentialModule]);
  reader = (import ../lib/default.nix).ai.claude-code.usageReader {
    inherit pkgs python-stack;
    claude = pkgs.emptyDirectory;
  };
in {
  checks.claude-code-usage-types = pkgs.runCommand "claude-code-usage-types" {nativeBuildInputs = [pkgs.pyright python];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    pyright --project ${../usage} --pythonpath "$(command -v python3)"
    test -x ${reader}/bin/claude-usage
    touch "$out"
  '';
}
