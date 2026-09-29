# One renderer for generated Markdown frontmatter and its guard metadata.
{lib}: let
  block = data:
    "---\n"
    + builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (key: value:
      if value == []
      then "${key}: []"
      else if builtins.isList value
      then "${key}:\n" + lib.concatMapStringsSep "\n" (item: "  - \"${item}\"") value
      else "${key}: ${value}")
    data)
    + "\n---\n";
in rec {
  inherit block;
  content = rendered: {
    _frontmatterKeys = rendered.keys;
    inherit (rendered) text;
  };

  render = {
    data,
    body,
  }: {
    text = lib.optionalString (data != {}) (block data + "\n") + body;
    frontmatter = data != {};
    keys = lib.attrNames data;
  };

  treeFile = rendered: {
    inherit (rendered) frontmatter text;
  };
}
