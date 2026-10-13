# Keep logical export names explicit; owner directories may be relocated.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) index load;
  owners = {
    chatgpt-codex = ../../packages/chatgpt-codex/extracted;
    claude-code = ../../packages/claude-code/extracted;
    git-absorb = ../../packages/git-absorb/extracted;
    git-branchless = ../../packages/git-branchless/extracted;
    git-revise = ../../packages/git-revise/extracted;
    glab = ../../packages/glab/extracted;
    kimchi = ../../packages/kimchi/extracted;
    kiro-cli = ../../packages/kiro-cli/extracted;
    kiro-model-catalog = ../../packages/kiro-model-catalog/extracted;
    semble = ../../packages/semble/extracted;
  };
in {
  checks.extracted-index = index (lib.mapAttrs (_: dir: load {inherit dir;}) owners);
}
