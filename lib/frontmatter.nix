# One renderer for generated Markdown frontmatter.
{lib}: let
  scalar = key: value:
    if value == null || builtins.isBool value || builtins.isInt value || builtins.isString value
    then builtins.toJSON value
    else throw "frontmatter: key '${key}' must be a string, boolean, integer, null, or a list of those scalars";
  block = data:
    "---\n"
    + builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (key: value:
      if builtins.isList value
      then
        if value == []
        then "${key}: []"
        else "${key}:\n" + lib.concatMapStringsSep "\n" (item: "  - ${scalar key item}") value
      else "${key}: ${scalar key value}")
    data)
    + "\n---\n";
in {
  inherit block;
  render = {
    data,
    body,
  }:
    lib.optionalString (data != {}) (block data + "\n") + body;
}
