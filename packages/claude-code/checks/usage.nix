# The Claude usage Reader type-checks strictly against the envelope and the
# transports it imports, and its packaged command builds.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  python = import ../lib/usage-python.nix {inherit pkgs python-stack;};
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
