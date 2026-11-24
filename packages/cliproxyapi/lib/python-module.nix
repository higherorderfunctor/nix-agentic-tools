# Install the owner's `usage` package as the `cliproxyapi` namespace for one
# python-stack interpreter. A consumer lists the result beside pydantic in
# `withPackages`, so its packaged program and checks import the module from that
# environment. delegate-routing's `usage.config` and the transport suite are the
# callers today.
#
# `toPythonModule` only marks the derivation: the environment merges the
# package's site-packages directory into its own.
{
  pkgs,
  python-stack,
}:
python-stack.pkgs.toPythonModule (pkgs.runCommand "cliproxyapi-usage" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  package="$out/${python-stack.sitePackages}/cliproxyapi/usage"
  mkdir -p "$package" # bare-commands: ok (runCommand builder PATH)
  cp ${../usage}/transport.py ${../usage}/py.typed "$package/" # bare-commands: ok (runCommand builder PATH)
'')
