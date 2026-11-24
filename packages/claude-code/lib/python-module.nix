# Install the Claude Reader for the command and conformance check that import it.
{
  pkgs,
  python-stack,
}:
python-stack.pkgs.toPythonModule (pkgs.runCommand "claude-code-usage" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  package="$out/${python-stack.sitePackages}/claude_code/usage"
  mkdir -p "$package" # bare-commands: ok (runCommand builder PATH)
  cp ${../usage}/*.py ${../usage}/py.typed "$package/" # bare-commands: ok (runCommand builder PATH)
'')
