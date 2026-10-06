{lib}: {
  resolveRouting = portable: runtime: portable // runtime;
  resolveWorkflows = portable: runtime:
    portable
    // lib.mapAttrs (name: workflow:
      workflow
      // {
        steps = (portable.${name}.steps or {}) // workflow.steps;
        # A runtime record that sets no header keeps the portable one.
        text =
          if workflow.text == ""
          then portable.${name}.text or ""
          else workflow.text;
      })
    runtime;
  sort = scope: entries: let
    enabled = lib.filterAttrs (_: entry: entry.enable) entries;
    names = builtins.attrNames enabled;
    selfCycles = builtins.filter (name: builtins.elem name (enabled.${name}.after ++ enabled.${name}.before)) names;
    result = lib.toposort (a: b:
      builtins.elem a enabled.${b}.after || builtins.elem b enabled.${a}.before)
    names;
  in
    if selfCycles != []
    then throw "${scope}: ordering cycle involving ${lib.concatStringsSep ", " selfCycles}"
    else if result ? cycle
    then throw "${scope}: ordering cycle involving ${lib.concatStringsSep ", " (lib.unique (result.cycle ++ result.loops))}"
    else
      map (name: {
        inherit name;
        value = enabled.${name};
      })
      result.result;
}
