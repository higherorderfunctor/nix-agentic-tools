# Inference, settings and catalog consumers read named facts from the pinned
# Claude Code bundle without evaluating a build.
{lib}: let
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
in
  facts.get (facts.load {dir = ../extracted;}).aggregate
