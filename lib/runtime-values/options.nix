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
      path = prefix ++ [name];
      secret = classify {
        inherit path;
        hints = field.hints or {};
      };
    in
      (lib.mkOption {
        type = lib.types.nullOr (types.withReferences {
          inherit (field) type;
          inherit secret;
        });
        default = null;
        description = field.description or "Runtime-configurable value.";
      })
      // {runtimeValueHints = field.hints or {};})
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
      else if type.name == "submodule"
      then visit path secret (type.getSubOptions path)
      else lib.optional secret (lib.showOption path);
    visit = path: secretContainer: node:
      if lib.isOption node
      then let
        secret = classify {
          inherit path secretContainer;
          hints = node.runtimeValueHints or {};
        };
      in
        auditType path secret node.type
      else if builtins.isAttrs node
      then
        lib.concatLists (lib.mapAttrsToList (name: child:
          if name == "_module"
          then []
          else
            visit
            (path ++ [name])
            secretContainer
            child)
        node)
      else [];
  in
    lib.concatMap (path: visit path false (lib.attrByPath path {} options)) roots;
in {
  inherit checkOptions fromSchema;
}
