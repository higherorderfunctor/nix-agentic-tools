# One typed leaf's contribution to a raw git-settings sink, shared by the tool
# module factory (./tool-module.nix) and the sandbox's definition-preserving
# copy-down (packages/microvm/modules/git.nix), so both lower a leaf the same
# way from whichever option tree owns it:
#
#   - a null scalar and an empty `<name>` family write nothing, so git (and
#     the tool) fall through to a lower configuration scope, key by key;
#   - every other leaf is written with the PRIORITY the option was defined at,
#     `mkOverride opt.highestPrio opt.value`, so a `mkDefault` preset stays a
#     default next to a raw value while an explicit typed value that disagrees
#     with a raw one is a loud definition conflict;
#   - the key path becomes git's `section.subsection.key` shape: everything
#     between the section and the key is one dotted subsection, and a family
#     is a subsection of its own (`branchless."test.alias".<name>`), the only
#     shape Home Manager's type admits (./ini-type.nix).
#
# `leaf.path` includes the section as its head (the generator's convention);
# `opt` is the leaf's own option, from which the priority is taken.
{lib}: let
  # ["branchless" "core" "mainBranch"] → ["branchless" "core" "mainBranch"];
  # ["branchless" "a" "b" "key"]       → ["branchless" "a.b" "key"];
  # family ["branchless" "test" "alias"] → ["branchless" "test.alias"].
  iniPath = leaf: let
    rest = lib.tail leaf.path;
  in
    if leaf.family
    then [(lib.head leaf.path) (lib.concatStringsSep "." rest)]
    else [(lib.head leaf.path)] ++ lib.optional (lib.length rest > 1) (lib.concatStringsSep "." (lib.init rest)) ++ [(lib.last rest)];
in {
  inherit iniPath;
  lower = leaf: opt:
    lib.optional (opt.value != null && opt.value != {})
    (lib.setAttrByPath (iniPath leaf) (lib.mkOverride opt.highestPrio opt.value));
}
