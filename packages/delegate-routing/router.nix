# The always-on entries (`always = true`), rendered as the text delivered
# through `ai.<runtime>.extraSystemPrompt.delegate-routing` (Kiro: the
# `delegate-routing-router` rule); null when no always-on entry is enabled.
{
  entries,
  lib,
  workflows ? {},
}: let
  renderer = import ./lib/render-entries.nix {inherit lib;};
  rendered = lib.concatStringsSep "\n" (lib.filter (text: text != "") [
    (renderer.routing true entries)
    (renderer.workflows true workflows)
  ]);
in
  if rendered == ""
  then null
  else "# Delegate routing\n\n${rendered}"
