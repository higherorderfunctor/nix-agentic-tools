# Shared approval checks for module options and direct skill builders.
{lib}: {
  classifiers,
  families,
}: let
  names = map (family: family.name) families;
  nonempty = value: builtins.isString value && lib.trim value != "";
  validPair = pair:
    builtins.isAttrs pair
    && builtins.attrNames pair == ["effort" "family"]
    && nonempty pair.family
    && nonempty pair.effort;
  validList = builtins.isList classifiers && lib.all validPair classifiers;
in [
  {
    assertion = validList && classifiers != [];
    message = "ai.programs.delegate-routing.classifiers: expected a non-empty list of { family; effort; } pairs with non-empty strings.";
  }
  {
    assertion = validList && lib.all (pair: builtins.elem pair.family names) classifiers;
    message = "ai.programs.delegate-routing.classifiers: every approved family must be configured.";
  }
  {
    assertion = validList && lib.allUnique classifiers;
    message = "ai.programs.delegate-routing.classifiers: duplicate family/effort approvals are not allowed.";
  }
  {
    assertion = lib.allUnique names;
    message = "ai.programs.delegate-routing.families: family names must be unique across vendors.";
  }
]
