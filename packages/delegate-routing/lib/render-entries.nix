{lib}: let
  entries = import ./resolve-entries.nix {inherit lib;};
  indentAfter = marker: text:
    marker + lib.replaceStrings ["\n"] ["\n${lib.concatStrings (lib.replicate (builtins.stringLength marker) " ")}"] (lib.removeSuffix "\n" text);
  stepText = scope: step: let
    rows = entries.sort "${scope}.rows" (step.rows or {});
    renderRows = marker: lib.concatStringsSep "\n" (lib.imap0 (index: row: indentAfter (marker index) row.value.text) rows);
  in
    if step.text == ""
    then throw "${scope}: enabled step must have non-empty text after row composition."
    else
      lib.replaceStrings ["{rows}" "{bullets}"] [
        (renderRows (index: "${toString (index + 1)}. "))
        (renderRows (_: "- "))
      ]
      step.text;
  heading = name: text: ''
    ### ${name}

    ${lib.removeSuffix "\n" text}
  '';
in {
  routing = always: routing:
    lib.concatMapStringsSep "\n" ({
      name,
      value,
    }:
      heading name value.text)
    (builtins.filter (entry: entry.value.always == always) (entries.sort "delegate-routing.routing" routing));
  workflows = always: workflows:
    lib.concatMapStringsSep "\n" ({
      name,
      value,
    }: let
      steps = entries.sort "delegate-routing.workflows.${name}.steps" value.steps;
      numbered = lib.concatStringsSep "\n\n" (lib.imap0 (index: step:
        indentAfter "${toString (index + 1)}. " "**${step.name}:** ${stepText "delegate-routing.workflows.${name}.steps.${step.name}" step.value}")
      steps);
    in
      if value.text == "" && steps == []
      then throw "delegate-routing.workflows.${name}: enabled workflow must have non-empty text or an enabled step."
      else heading name (value.text + lib.optionalString (numbered != "") "\n\n${numbered}"))
    (builtins.filter (entry: entry.value.always == always) (entries.sort "delegate-routing.workflows" workflows));
}
