# One git tool's consumer module, the same on Home Manager and devenv:
#
#   git.<section>.enable     installs the tool (home.packages / packages)
#   git.<section>.settings   the typed tree ./default.nix generates from the
#                            tool's sidecar, mounted at the git key path
#                            under the tool's section: the option
#                            git.absorb.settings.maxStack is the key
#                            absorb.maxStack
#
# The typed tree is lowered into `git.settings` (packages/git), the one
# attrset of git configuration both backends deliver: Home Manager aliases it
# to `programs.git.settings`, devenv renders it into a repository-local
# include. So this is the only renderer; nothing lowers a typed value twice.
#
# Lowering (`lower` below):
#   - a null scalar and an empty `<name>` family write nothing, so git (and
#     the tool) fall through to a lower configuration scope, key by key;
#   - every other leaf is written with the PRIORITY it was defined at,
#     `mkOverride opt.highestPrio opt.value`. A value a preset set with
#     `mkDefault` therefore stays a default next to a raw `git.settings` /
#     `programs.git.settings` value, while an explicit typed value that
#     disagrees with a raw one is a loud definition conflict rather than a
#     silent shadow. A family carries one priority for the whole map: the
#     highest-priority definition of the map as a value.
#   - the key path becomes git's `section.subsection.key` shape: everything
#     between the section and the key is one dotted subsection, and a family
#     is a subsection of its own (`branchless."test.alias".<name>`), the only
#     shape Home Manager's type admits (./ini-type.nix).
{
  # "homeManager" or "devenv": where `enable` puts the package.
  backend,
  # This flake's package tree (`ai.internal.packages`) → the tool's derivation.
  package,
  # The git config section, which is also the option name: "absorb".
  section,
  # The owner's generator result: `lib.<owner>.settings {lib}`.
  settings,
  # The program's name, for descriptions.
  tool,
  # The typed option tree; an owner may pass an amended copy of
  # `settings.options.<section>` (a longer description, say).
  settingsOptions ? settings.options.${section},
  # Replaces the generic `enable` description, for a tool whose enable does
  # more than install it.
  enableDescription ? null,
}: {
  config,
  lib,
  options,
  ...
}: let
  cfg = config.git.${section};
  typed = options.git.${section}.settings;

  # ["branchless" "core" "mainBranch"] → ["branchless" "core" "mainBranch"];
  # ["branchless" "a" "b" "key"]       → ["branchless" "a.b" "key"];
  # family ["branchless" "test" "alias"] → ["branchless" "test.alias"].
  iniPath = leaf: let
    rest = lib.tail leaf.path;
  in
    if leaf.family
    then [(lib.head leaf.path) (lib.concatStringsSep "." rest)]
    else [(lib.head leaf.path)] ++ lib.optional (lib.length rest > 1) (lib.concatStringsSep "." (lib.init rest)) ++ [(lib.last rest)];

  lower = leaf: let
    opt = lib.getAttrFromPath (lib.tail leaf.path) typed;
  in
    lib.optional (opt.value != null && opt.value != {})
    (lib.setAttrByPath (iniPath leaf) (lib.mkOverride opt.highestPrio opt.value));
in {
  options.git.${section} = {
    enable =
      lib.mkEnableOption "${tool}, installed from this flake's package"
      // lib.optionalAttrs (enableDescription != null) {description = enableDescription;};
    settings = settingsOptions;
  };

  config = lib.mkMerge [
    {git.settings = lib.mkMerge (lib.concatMap lower settings.leaves);}
    (lib.mkIf cfg.enable (
      if backend == "homeManager"
      then {home.packages = [(package config.ai.internal.packages)];}
      else {packages = [(package config.ai.internal.packages)];}
    ))
  ];
}
