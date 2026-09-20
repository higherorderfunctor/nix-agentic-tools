let
  baseRule = {
    description = "Size model and effort before delegating";
    text = builtins.readFile ./fragments/skill-routing.md;
  };
  render = {
    entries,
    lib,
  }: let
    enabledEntries = lib.filterAttrs (_: entry: entry.enable) entries;
    renderedEntries = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
        ### ${name}

        ${lib.removeSuffix "\n" entry.text}
      '')
      enabledEntries);
  in {
    delegate-sizing-router =
      baseRule
      // {
        text = baseRule.text + lib.optionalString (renderedEntries != "") "\n${renderedEntries}";
      };
  };
in {
  __functor = _: render;
  delegate-sizing-router = baseRule;
}
