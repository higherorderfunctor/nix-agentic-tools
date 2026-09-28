# This repository's Markdown formatter, as a shell snippet for
# `ai.markdown.formatter` and `markdown.mkTree`: treefmt with the house config
# (treefmt.nix), over the tree in the working directory.
#
# The RAW treefmt binary with explicit flags, deliberately. devenv's `treefmt`
# wrapper hardcodes the project directory as the tree root, and treefmt-nix's
# `build.wrapper` looks for `projectRootFile`, which a build sandbox does not
# have; `--tree-root .` makes the tree being built the root. The house config's
# excludes apply by path inside that tree, which is why treefmt.nix excludes no
# file `ai.*` generates.
{
  pkgs,
  treefmt-nix,
}: let
  treefmt = (treefmt-nix.lib.evalModule pkgs (import ../treefmt.nix)).config;
in {
  formatter = "${pkgs.lib.getExe treefmt.package} --config-file ${treefmt.build.configFile} --tree-root . --walk filesystem --no-cache";
}
