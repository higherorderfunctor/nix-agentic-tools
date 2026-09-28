# dev/repo-docs.nix — the two generated repo-root documents (README.md,
# CONTRIBUTING.md), rendered from dev/generate.nix and formatted and checked
# in the sandbox by the same builder and house formatter as the generated
# agent Markdown (lib/markdown, dev/house-markdown.nix).
#
# These are HUMAN documents, not agent steering, so they stay with the
# generator. The agent instruction files are `ai.*`'s to write (dev/ai.nix).
#
# Consumed by flake.nix (`packages.<system>.repo-*`), which the
# `generate:repo:*` tasks build and copy out, and which the drift check
# compares against the tracked copies.
{
  lib,
  pkgs,
  treefmt-nix,
}: let
  gen = import ./generate.nix {inherit lib pkgs;};
  markdown = import ../lib/markdown {inherit lib;} pkgs;
  house = import ./house-markdown.nix {inherit pkgs treefmt-nix;};

  # One generated file, built, formatted and checked the way `ai.*` builds
  # generated Markdown, so the copy `generate:repo:*` drops in the working
  # tree is already what the formatter would produce.
  doc = name: filename: text:
    markdown.mkTree {
      inherit name;
      files.${filename}.text = text;
      inherit (house) formatter;
      check = markdown.defaultCheck;
    };
in {
  repoContributing = doc "repo-contributing" "CONTRIBUTING.md" gen.contributingMd;
  repoReadme = doc "repo-readme" "README.md" gen.readmeMd;
}
