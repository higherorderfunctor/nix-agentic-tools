# One value as a single-line TOML expression, for a `-c key=value` session
# flag: Codex splits an override's key path at every dot, so anything nested
# travels as one inline table. Keys are quoted, so a key that is itself a path
# survives; JSON string escapes are valid TOML basic strings.
{lib}: let
  render = value:
    if builtins.isAttrs value
    then "{" + lib.concatStringsSep ", " (lib.mapAttrsToList (key: item: "${builtins.toJSON key} = ${render item}") value) + "}"
    else if builtins.isList value
    then "[" + lib.concatMapStringsSep ", " render value + "]"
    else builtins.toJSON value;
in
  render
