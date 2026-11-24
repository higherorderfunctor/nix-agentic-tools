# Install the owner's `credential_usage` package for one python-stack
# interpreter. A consumer lists the result beside pydantic in `withPackages`,
# so its packaged program and checks import the module from that environment.
#
# `toPythonModule` only marks the derivation: the environment merges the
# package's site-packages directory into its own.
{
  pkgs,
  python-stack,
}:
python-stack.pkgs.toPythonModule (pkgs.runCommand "credential-usage" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  mkdir -p "$out/${python-stack.sitePackages}" # bare-commands: ok (runCommand builder PATH)
  cp -r ${../python}/credential_usage "$out/${python-stack.sitePackages}/credential_usage" # bare-commands: ok (runCommand builder PATH)
'')
