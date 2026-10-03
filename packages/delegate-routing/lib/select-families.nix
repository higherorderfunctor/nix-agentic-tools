# Non-empty selector fields are conjunctive; selectors themselves are alternatives.
{lib}: families: selectors:
builtins.filter
(family:
    lib.any
    (selector: let
      fields = lib.filterAttrs (_: values: values != []) selector;
      values = {
        families = family.name;
        tiers = family.tier;
        vendors = family.vendor;
      };
    in
      fields != {} && lib.all (field: builtins.elem values.${field} fields.${field}) (builtins.attrNames fields))
    selectors)
(lib.concatMap
  (vendor: lib.mapAttrsToList (name: family: family // {inherit name vendor;}) families.${vendor})
  (builtins.attrNames families))
