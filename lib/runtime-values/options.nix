{
  lib,
  types,
  classify,
}: let
  fromSchema = {
    fields,
    prefix,
  }:
    lib.mapAttrs (name: field: let
      inherit (field) description hints;
      path = prefix ++ [name];
      secret = classify {
        inherit hints path;
      };
    in
      (lib.mkOption {
        type = lib.types.nullOr (types.withReferences {
          inherit (field) type;
          inherit secret;
        });
        default = null;
        inherit description;
      })
      // {runtimeValueHints = hints;})
    fields;
  checkOptions = {
    options,
    roots,
  }: let
    auditType = path: secret: type:
      if type.name == "nullOr"
      then auditType path secret type.nestedTypes.elemType
      else if type ? runtimeValue
      then lib.optional (secret && !type.runtimeValue.secret) (lib.showOption path)
      else if type ? runtimeValueMap
      then lib.optional (secret && !type.runtimeValueMap.secretContainer) (lib.showOption path)
      else if type.name == "attrsOf"
      then auditType path secret type.nestedTypes.elemType
      else if type.name == "submodule"
      then
        if secret
        then [lib.showOption path]
        else visit path (type.getSubOptions path)
      else lib.optional secret (lib.showOption path);
    visit = path: node:
      if lib.isOption node
      then let
        secret = classify {
          inherit path;
          hints = node.runtimeValueHints or {};
        };
      in
        auditType path secret node.type
      else if builtins.isAttrs node
      then
        lib.concatLists (lib.mapAttrsToList (name: child:
          if name == "_module"
          then []
          else visit (path ++ [name]) child)
        node)
      else [];
  in
    lib.concatMap (path: visit path (lib.attrByPath path {} options)) roots;
in {
  inherit checkOptions fromSchema;
}
