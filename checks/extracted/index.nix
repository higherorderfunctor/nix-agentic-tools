# The aggregate facts JSON for readers outside Nix (dev tasks, skills):
# build `checks.<system>.extracted-index` and read `<owner>.json` or
# `index.json` from it. Every owner that has migrated to the facts contract
# is listed by its `extracted/` directory.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) index load;
  owners = [
    {
      dir = ../../packages/chatgpt-codex/extracted;
      name = "chatgpt-codex";
    }
    {
      dir = ../../packages/claude-code/extracted;
      name = "claude-code";
    }
    {
      dir = ../../packages/kimchi/extracted;
      name = "kimchi";
    }
    {
      dir = ../../packages/kiro-cli/extracted;
      name = "kiro-cli";
    }
  ];
in {
  checks.extracted-index = index (lib.listToAttrs (map (owner: lib.nameValuePair owner.name (load {inherit (owner) dir;})) owners));
}
