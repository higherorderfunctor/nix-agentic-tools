# Inference and network proxy selections share registration and enable checks;
# callers supply their existing diagnostic wording.
{
  lib,
  disabled,
  unregistered,
}: registry: option: name: let
  entry = registry.${name} or null;
  context = {
    inherit entry name option;
    registered =
      if registry == {}
      then "none"
      else lib.concatStringsSep ", " (builtins.attrNames registry);
  };
in
  if entry == null
  then {problem = unregistered context;}
  else if !entry.enable
  then {problem = disabled context;}
  else {inherit entry;}
