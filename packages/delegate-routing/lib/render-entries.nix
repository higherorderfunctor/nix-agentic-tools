{lib}: let
  entries = import ./resolve-entries.nix {inherit lib;};
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
      numbered = lib.concatStringsSep "\n\n" (lib.imap0 (index: step: let
        marker = "${toString (index + 1)}. ";
        indent = lib.concatStrings (lib.replicate (builtins.stringLength marker) " ");
        text = lib.replaceStrings ["\n"] ["\n${indent}"] (lib.removeSuffix "\n" step.value.text);
      in "${marker}**${step.name}:** ${text}")
      steps);
    in
      if value.text == "" && steps == []
      then throw "delegate-routing.workflows.${name}: enabled workflow must have non-empty text or an enabled step."
      else heading name (value.text + lib.optionalString (numbered != "") "\n\n${numbered}"))
    (builtins.filter (entry: entry.value.always == always) (entries.sort "delegate-routing.workflows" workflows));
}
