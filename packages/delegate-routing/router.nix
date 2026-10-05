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
in {
  delegate-routing-router = {
    description = "Load delegate-routing before delegating work";
    text = "# Delegate routing\n" + lib.optionalString (rendered != "") "\n${rendered}";
  };
}
