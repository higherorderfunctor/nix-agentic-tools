# Non-empty selector fields are conjunctive; selectors themselves are alternatives.
{lib}: let
  inherit (import ./vocabulary.nix) tiers;
  tierRanks = builtins.listToAttrs (lib.imap0 (value: name: {inherit name value;}) tiers);
  automatic = {
    runtime,
    extraRuntimes,
    manualExternalDelegates,
  }:
    [runtime] ++ lib.subtractLists manualExternalDelegates (lib.unique extraRuntimes);
  candidates = families: models: runtimes:
    lib.unique (lib.concatMap (runtime: select families models.${runtime}) runtimes);
  flatten = families:
    lib.concatMap
    (vendor: lib.mapAttrsToList (name: family: family // {inherit name vendor;}) families.${vendor})
    (builtins.attrNames families);
  select = families: selectors:
    lib.sort
    (a: b: tierRanks.${a.tier} < tierRanks.${b.tier})
    (builtins.filter
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
      (flatten families));
in {
  inherit automatic candidates flatten select;
}
