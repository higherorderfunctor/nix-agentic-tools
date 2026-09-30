# The value type of git configuration as an attrset: Home Manager's
# `gitIniType` (home-manager modules/programs/git.nix, the type of
# `programs.git.settings`), copied because this flake does not depend on
# Home Manager.
#
# Three consumers must agree on it, so it lives here once:
#   - the devenv `git.settings` option (packages/git), so a value that
#     evaluates on devenv also evaluates on Home Manager;
#   - the Home Manager stub in lib/testing/module-harness.nix, so checks
#     reject what real Home Manager rejects;
#   - the Home Manager stub in lib/options-doc.nix.
#
# It admits at most `section.subsection.key`. A key four levels deep, such as
# git-branchless's `branchless.test.alias.<name>`, must be written with a
# dotted subsection (`branchless."test.alias".<name>`); `lib.generators.toGitINI`
# renders both shapes the same way, but this type rejects the nested one.
# `null` is not a value: a key that should not be written must be absent.
{lib}: let
  inherit (lib) types;
  primitiveType = types.either types.str (types.either types.bool types.int);
  multipleType = types.either primitiveType (types.listOf primitiveType);
  sectionType = types.attrsOf multipleType;
  supersectionType = types.attrsOf (types.either multipleType sectionType);
in
  types.attrsOf supersectionType
