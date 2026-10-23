# Read CPA's embedded OAuth vendor rows; exact mode and its shape controls
# consume the same expression. Values remain byte-identical model IDs.
{lib}: raw: let
  ids = vendor: let
    rows =
      if builtins.isAttrs raw
      then raw.${vendor} or null
      else null;
  in
    if !builtins.isList rows || rows == [] || !(lib.all (row: builtins.isAttrs row && builtins.isString (row.id or null)) rows)
    then throw "CPA embedded models catalog changed shape"
    else map (row: row.id) rows;
in {
  claude = ids "claude";
  codex = lib.unique (lib.concatMap ids ["codex-free" "codex-plus" "codex-pro" "codex-team"]);
}
