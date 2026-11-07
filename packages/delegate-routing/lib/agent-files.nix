# One resolved family set backs both generated files and their launch routes.
{lib}: let
  frontmatter = import ../../../lib/frontmatter.nix {inherit lib;};
  extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  fact = extracted.get (extracted.load {dir = ../../claude-code/extracted;}).aggregate;
  facts = lib.genAttrs ["effortLevels" "models"] fact;
  pattern = glob:
    lib.concatMapStrings (char:
      if char == "*"
      then ".*"
      else if char == "?"
      then "."
      else if builtins.elem char ["." "+" "(" ")" "{" "}" "^" "$" "|" "\\"]
      then "\\${char}"
      else char) (lib.stringToCharacters glob);
  # Compare numeric segments, including hyphenated versions: 10 > 9, 5-1 > 5.
  version = id: map lib.toInt (builtins.filter (part: builtins.isString part && part != "") (builtins.split "[^0-9]+" id));
  newer = a: b: lib.compareLists lib.compare (version a) (version b) < 0;
  resolveId = ids: family: let
    example = family.example.claude or "";
    matches = builtins.filter (id: builtins.match (pattern family.match) id != null) ids;
  in
    if lib.trim example != ""
    then example
    else if matches == []
    then null
    else lib.last (lib.sort newer matches);
  resolve = ids: families:
    lib.listToAttrs (lib.concatMap (family: let
      id = resolveId ids family;
    in
      lib.optional (id != null) {
        inherit (family) name;
        value = {inherit family id;};
      })
    families);
  render = {
    family,
    id,
  }:
    frontmatter.render {
      data =
        {
          description = "delegate-routing launch vehicle for the ${family.name} (${family.vendor}) family: ${family.useFor}";
          model = id;
          inherit (family) name;
        }
        // lib.optionalAttrs ((family.defaultEffort or null) != null) {effort = family.defaultEffort;};
      body = "You are a delegate launched by an orchestrator through the delegate-routing skill. Your prompt carries the task; do it and report the result with its evidence. You are non-interactive: decide, act, return. This file pins the model and the family's default effort; an effort passed in the launch call overrides the file.\n";
    };
in {
  inherit facts render resolve resolveId;
}
