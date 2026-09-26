# dev/repo-docs.nix — the two generated repo-root documents (README.md,
# CONTRIBUTING.md), rendered from dev/generate.nix and formatted in the
# sandbox.
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

  # treefmt for use inside derivations. Same config as treefmt.nix
  # but with projectRootFile disabled — no .git in nix sandbox.
  fmtDrv =
    (treefmt-nix.lib.evalModule pkgs (
      lib.recursiveUpdate (import ../treefmt.nix) {projectRootFile = null;}
    ))
    .config
    .build
    .wrapper;

  # A directory holding one generated file, formatted with treefmt before
  # the derivation finishes, so the copy `generate:repo:*` drops in the
  # working tree is already what the formatter would produce. The store
  # file is read-only; chmod makes the derivation's own $out writable for
  # treefmt.
  formattedDoc = name: filename: text:
    pkgs.runCommand name {nativeBuildInputs = [fmtDrv];} ''
      mkdir -p $out
      cp ${pkgs.writeText filename text} $out/${filename}
      chmod -R u+w $out
      treefmt --no-cache --walk filesystem --tree-root $out
    '';
in {
  repoContributing = formattedDoc "repo-contributing" "CONTRIBUTING.md" gen.contributingMd;
  repoReadme = formattedDoc "repo-readme" "README.md" gen.readmeMd;
}
