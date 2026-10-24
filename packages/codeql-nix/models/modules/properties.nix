{lib}: let
  property = name: arity: value: {
    inherit arity name;
    kind = value._type;
    priority =
      if arity == 1 && value ? priority
      then toString value.priority
      else null;
    evidence = map (set: builtins.unsafeGetAttrPos name set) [lib lib.modules];
  };
in {
  constantEvidence.ordinaryOverridePriority = builtins.unsafeGetAttrPos "defaultOverridePriority" lib.modules;
  constants = {
    ordinaryOverridePriority = toString lib.modules.defaultOverridePriority;
  };
  helpers = [
    (property "mkAfter" 1 (lib.mkAfter null))
    (property "mkBefore" 1 (lib.mkBefore null))
    (property "mkDefault" 1 (lib.mkDefault null))
    (property "mkForce" 1 (lib.mkForce null))
    (property "mkIf" 2 (lib.mkIf false null))
    (property "mkMerge" 1 (lib.mkMerge []))
    (property "mkOrder" 2 (lib.mkOrder 0 null))
    (property "mkOverride" 2 (lib.mkOverride 0 null))
  ];
}
