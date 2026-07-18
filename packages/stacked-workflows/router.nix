# Stacked-workflow router: the routing-table instruction contributed to
# `ai.instructions` (→ Claude CLAUDE.md, Kiro steering, Copilot instructions).
# Shared by the HM (user-global) and devenv (project) modules so the router
# content stays single-source.
{
  lib,
  pkgs,
}: let
  fragments = import ../../lib/fragments.nix {inherit lib;};
  swsContent = pkgs.stacked-workflows-content;
  composed = fragments.compose {
    fragments = builtins.attrValues swsContent.passthru.fragments;
    description = "Stacked workflow routing table and skill usage";
  };
in [
  {
    name = "stacked-workflows";
    inherit (composed) text;
    description = "Stacked workflow routing table and skill usage";
  }
]
