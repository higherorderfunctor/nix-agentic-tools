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
# The factory is parameterized by where the tree mounts and where its two
# outputs go, so one invocation serves every consumer of a tool's options.
# The host backends
# mount at `root = ["git"]`, lower into `sink = ["settings"]` and install on
# `backend`; the sandbox (packages/microvm/modules/git.nix) mounts one tree
# per runtime at `["ai" <runtime> "sandbox" "git"]`, lowers into the runtime's
# `_ini` render sink, defaults `enable` to the shared root's and installs the
# package into the guest's package list. Host instantiations pass none of the
# parameters below.
{
  # "homeManager" or "devenv": where `enable` puts the package when `install`
  # is not given. A tree that is not installed on this evaluation's host (the
  # sandbox) passes `install` and no backend.
  backend ? null,
  # This flake's package tree (`ai.internal.packages`) → the tool's derivation.
  package,
  # The git config section, which is also the option name: "absorb".
  section,
  # The owner's generator result: `lib.<owner>.settings {lib}`. Its optional
  # `assertions` (a list of `{cfg; optionPath;}` → `{assertion; message}`)
  # hold the per-tool checks that must hold wherever the tree mounts.
  settings,
  # The program's name, for descriptions.
  tool,
  # An option path whose boolean value is this `enable`'s default: the
  # sandbox's runtime trees default to the shared root's enable, which a
  # runtime's own definition (any priority) replaces.
  enableFrom ? null,
  # Replaces the generic `enable` description, for a mount whose enable does
  # more than the host's install.
  enableDescription ? null,
  # Where `enable` installs the tool's package: an option path relative to
  # `root` (the sandbox's internal guest package list), or null to defer to
  # `backend`'s host sink.
  install ? null,
  # The option root the tree mounts at. The host backends mount at ["git"];
  # the sandbox mounts one tree per runtime at ["ai" <runtime> "sandbox" "git"].
  root ? ["git"],
  # The typed option tree; an owner may pass an amended copy of
  # `settings.options.<section>` (a longer description, say).
  settingsOptions ? settings.options.${section},
  # The option path, relative to `root`, the typed settings lower into. The
  # host's raw sink is `git.settings` (packages/git); the sandbox lowers into
  # its internal `_ini` render sink. null declares the tree without lowering:
  # the sandbox's shared root is lowered per runtime with each definition's
  # priority (packages/microvm/modules/git.nix), not into a sink of its own.
  sink ? ["settings"],
  # Checks this mount adds beside the owner's `settings.assertions`, in the
  # same `{cfg; optionPath}` shape: what the Git scope the tree writes into
  # adds. Home Manager passes git-branchless's `lowestScopeAssertions` (its
  # user-global file is the lowest layer that flake writes, so an unset leaf
  # there is upstream's default) and so does the sandbox (its system file is
  # the guest's lowest scope); repository-local scopes pass none, because a
  # higher scope may still supply the leaf.
  assertions ? [],
}: {
  config,
  lib,
  options,
  ...
}: let
  lower = import ./lower.nix {inherit lib;};
  cfg = lib.getAttrFromPath (root ++ [section]) config;
  typed = (lib.getAttrFromPath (root ++ [section]) options).settings;
  toolPackage = package config.ai.internal.packages;
  # The shared root's enable reaches this tree as its default, exactly as the
  # sandbox's other root leaves supply runtime defaults; a definition here
  # replaces it at any priority.
  enableDefault = lib.optionalAttrs (enableFrom != null) {
    default = let
      source = lib.getAttrFromPath enableFrom options;
    in
      if source.highestPrio < 1500
      then lib.getAttrFromPath enableFrom config
      else false;
  };
  lowered = lib.mkMerge (
    lib.concatMap
    (leaf: lower.lower leaf (lib.getAttrFromPath (lib.tail leaf.path) typed))
    settings.leaves
  );
in {
  options = lib.setAttrByPath (root ++ [section]) {
    enable =
      (lib.mkEnableOption "${tool}, installed from this flake's package"
        // lib.optionalAttrs (enableDescription != null) {description = enableDescription;})
      // enableDefault;
    settings = settingsOptions;
  };

  # A tree with neither `backend` nor `install` (the sandbox's shared root)
  # installs nothing: its `enable` exists to feed `enableFrom` defaults and
  # the per-runtime trees, which do install.
  config = lib.mkMerge (
    [
      # The per-tool checks the owner's generator result carries plus whatever
      # this mount's scope adds, evaluated wherever the tree mounts;
      # `optionPath` names the mounted root so the messages stay true at
      # every root.
      {
        assertions = map (
          check:
            check {
              inherit cfg;
              optionPath = lib.concatStringsSep "." (root ++ [section]);
            }
        ) ((settings.assertions or []) ++ assertions);
      }
    ]
    ++ lib.optional (sink != null) (lib.setAttrByPath (root ++ sink) lowered)
    ++ lib.optional (install != null || backend != null)
    (lib.mkIf cfg.enable (
      if install != null
      then lib.setAttrByPath (root ++ install) [toolPackage]
      else if backend == "homeManager"
      then {home.packages = [toolPackage];}
      else {packages = [toolPackage];}
    ))
  );
}
