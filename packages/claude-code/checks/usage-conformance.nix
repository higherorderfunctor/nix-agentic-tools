# Replay Claude's golden cases on both transports and type-check the installed Reader.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  moduleArgs = {inherit pkgs python-stack;};
  conformance = (import ../../credential-usage/lib/default.nix).ai.credential-usage.conformanceCheck (moduleArgs
    // {
      name = "claude-code-usage-conformance";
      ownerModules = [((import ../lib/default.nix).ai.claude-code.pythonModule moduleArgs)];
      pair = ../usage/cases;
      entry = "claude_code.usage.cli:main";
    });
in {
  checks.claude-code-usage-conformance = conformance;
  checks.claude-code-usage-types = pkgs.runCommand "claude-code-usage-types" {nativeBuildInputs = [pkgs.pyright conformance.python];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    pyright --project ${../usage} --pythonpath "$(command -v python3)"
    touch "$out"
  '';
}
