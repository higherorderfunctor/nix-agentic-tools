{
  inputs,
  pkgs,
  self,
}:
# Hard CI gate that fails when any tracked file is not formatted
# according to treefmt.nix. Mirrors what treefmt would catch in the
# pre-commit hook locally, but enforces it from the source tree
# rather than staged files — covers cases like --no-verify commits.
{
  formatting = (inputs.treefmt-nix.lib.evalModule pkgs (import ../treefmt.nix))
    .config
    .build
    .check
  self;
}
