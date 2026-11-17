{
  entries,
  lib,
  workflows ? {},
  stepPhrase ? null,
}: let
  renderer = import ./lib/render-entries.nix {inherit lib stepPhrase;};
  rendered = lib.concatStringsSep "\n" (lib.filter (text: text != "") [
    (renderer.routing true entries)
    (renderer.workflows true workflows)
  ]);
in
  lib.optionalAttrs (rendered != "") {
    delegate-routing-router = {
      description = "Load delegate-routing before delegating work";
      text = "# Delegate routing\n\n${rendered}";
    };
  }
