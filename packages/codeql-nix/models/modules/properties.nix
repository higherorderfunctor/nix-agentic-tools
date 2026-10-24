{lib}: let
  helper = name: arity: kind: priority: {
    inherit arity kind name priority;
    evidence = map (set: builtins.unsafeGetAttrPos name set) [lib lib.modules];
  };
  property = name: arity: value:
    helper name arity value._type (
      if arity == 1 && value ? priority
      then toString value.priority
      else null
    );
  rename = name: kind: helper name 2 kind null;
in {
  constantEvidence.ordinaryOverridePriority = builtins.unsafeGetAttrPos "defaultOverridePriority" lib.modules;
  constants = {
    ordinaryOverridePriority = toString lib.modules.defaultOverridePriority;
  };
  helpers = [
    (property "mkAfter" 1 (lib.mkAfter null))
    (rename "mkAliasOptionModule" "alias")
    (property "mkBefore" 1 (lib.mkBefore null))
    (property "mkDefault" 1 (lib.mkDefault null))
    (property "mkForce" 1 (lib.mkForce null))
    (property "mkIf" 2 (lib.mkIf false null))
    (property "mkMerge" 1 (lib.mkMerge []))
    (property "mkOrder" 2 (lib.mkOrder 0 null))
    (property "mkOverride" 2 (lib.mkOverride 0 null))
    (rename "mkRenamedOptionModule" "rename")
  ];
}
