# One renderer for generated Markdown frontmatter and its guard metadata.
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
in rec {
  inherit block;
  content = rendered: {
    _frontmatter = rendered.frontmatter;
    inherit (rendered) text;
  };

  render = {
    data,
    body,
  }: {
    text = lib.optionalString (data != {}) (block data + "\n") + body;
    frontmatter = data != {};
  };

  treeFile = rendered: {
    inherit (rendered) frontmatter text;
  };
}
