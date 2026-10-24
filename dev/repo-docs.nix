# dev/repo-docs.nix — the two generated repo-root documents (README.md,
# CONTRIBUTING.md), rendered from dev/generate.nix and formatted and checked
# in the sandbox by the same builder and house formatter as the generated
# agent Markdown (lib/generated.nix).
#
# These are HUMAN documents, not agent steering, so they stay with the
# generator. The agent instruction files are `ai.*`'s to write (dev/ai.nix).
#
# Consumed by flake.nix (`packages.<system>.repo-*`), which the
# `generate:repo:*` tasks build and copy out, and which the drift check
# compares against the tracked copies.
{
  inputs,
  lib,
  pkgs,
}: let
  gen = import ./generate.nix {inherit lib pkgs;};
  ai = import ../lib/ai {inherit lib;};
  generated = ai.generated pkgs;
  treefmt = (inputs.treefmt-nix.lib.evalModule pkgs (import ../treefmt.nix {inherit inputs;})).config;

  # One generated file, built, formatted and checked the way `ai.*` builds
  # generated Markdown, so the copy `generate:repo:*` drops in the working
  # tree is already what the formatter would produce.
  doc = name: filename: text:
    generated.mkTree {
      inherit name;
      files.${filename} = {
        inherit text;
        type = "markdown";
      };
      guards = {
        parseCompare = true;
        splitCodeSpans = true;
        tableCells = true;
      };
      runtime = "repository";
      inherit treefmt;
    };
in {
  repoContributing = doc "repo-contributing" "CONTRIBUTING.md" gen.contributingMd;
  repoReadme = doc "repo-readme" "README.md" gen.readmeMd;
}
