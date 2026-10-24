# Original user modules, shared by the independent oracle and installed fixture.
{variant ? "G"}: let
  child = {
    _file = "child.nix";
    key = "child";
  };
  pathChild = variant == "path-disable" || variant == "relative-disable";
  root = {
    _file = "root.nix";
    disabledModules =
      if variant == "no-disabling" || variant == "roots-only" || variant == "anon-key"
      then []
      else if variant == "disable-root"
      then [{key = "root";}]
      else if variant == "anon-disable"
      then [{key = ":anon-2";}]
      else if variant == "path-disable"
      then [./path-child.nix]
      else if variant == "relative-disable"
      then ["path-child.nix"]
      else [{key = "child";}];
    imports =
      if variant == "roots-only"
      then []
      else if pathChild
      then [./path-child.nix]
      else [
        (child
          // (
            if variant == "disabled-throw"
            then {imports = [(throw "M3g disabled import sentinel")];}
            else {}
          ))
        (child
          // (
            if variant == "other-key"
            then {key = "other";}
            else {}
          ))
      ];
    key =
      if variant == "anon-key"
      then ":anon-2"
      else "root";
  };
in {
  inherit root;
}
