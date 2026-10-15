# Generic key-name policy. Inspection warns and returns the original value;
# refusal is an explicit, separate policy selected by the owner of a surface.
{lib}: let
  warnings = import ./warnings.nix {inherit lib;};
  patterns = import ./patterns.nix;
  boundaries = ["([A-Z]+)([A-Z][a-z])" "([a-z0-9])([A-Z])"];
  normalize = name:
    lib.toLower (lib.replaceStrings ["-" "."] ["_" "_"] (
      lib.foldl' (acc: boundary:
        lib.concatMapStrings (part:
          if builtins.isList part
          then lib.concatStringsSep "_" part
          else part)
        (builtins.split boundary acc))
      name
      boundaries
    ));
  credentialReason = name: let
    lowered = normalize name;
    matches = builtins.filter (suffix: lib.hasSuffix "_${suffix}" ("_" + lowered)) (builtins.attrNames patterns);
  in
    if matches == []
    then null
    else patterns.${builtins.head matches};
  check = {
    name,
    optionPath ? [],
  }: let
    reason = credentialReason name;
  in {
    inherit reason;
    assertion = reason == null;
    message = "${lib.showOption (optionPath ++ [name])} cannot be set: ${
      if reason == null
      then "no refusal applies"
      else reason
    }.";
  };
in
  warnings
  // {
    inherit check credentialReason;
  }
