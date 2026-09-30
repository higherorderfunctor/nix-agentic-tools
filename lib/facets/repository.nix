{
  inputs,
  registryModules ? null,
  root,
  systems,
}: let
  inherit (inputs.nixpkgs) lib;
  facets = import ../facets.nix {inherit lib;};
  registry =
    import ./registry.nix ({inherit lib root;}
      // lib.optionalAttrs (registryModules != null) {modules = registryModules;});
  inherit (registry) index repoPath;
  inherit (registry.config) update;
  cacheHitParity = registry.config.checks.cacheHitParity;
  # The git tools' census builder, handed to owner packages and checks as an
  # argument so an owner never reaches into lib/ by a relative path (the
  # facet-owner-relocation check moves an owner and re-evaluates it).
  gitToolExtraction = import ../git-tool-settings/extraction.nix;
  packageWorlds = lib.genAttrs systems (system:
    facets.realizePackages {
      inherit index inputs system;
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      scopeArgs = {
        inherit gitToolExtraction repoPath;
        packageLib = import ../packaging.nix;
        fragmentsLib = import ../fragments.nix {inherit lib;};
        traceSource = import ../traceSource.nix {inherit lib;};
      };
    });
  # Overlay attribute names must be available before the nixpkgs fixed point
  # can supply stdenv/system. Discover the outer namespace without realization.
  packageRoots =
    lib.unique (map (claim: builtins.head claim.keyPath)
      (lib.concatMap (owner: owner.contributions.packages) index.owners));
in {
  inherit cacheHitParity index packageWorlds repoPath update;
  libraryFor = rootLibrary:
    facets.realizeLibrary {
      inherit index rootLibrary;
      rootSource = root + "/lib";
      context = {inherit inputs lib repoPath;};
    };
  packagesFor = {
    system,
    pkgs,
    rootPackages ? {},
  }:
    facets.flattenPackages {
      inherit pkgs rootPackages;
      packageWorld = packageWorlds.${system};
      rootSource = root + "/flake.nix";
    };
  overlay = final: prev: let
    system = final.stdenv.hostPlatform.system;
    context = {
      inherit inputs lib system;
      inherit (packageWorlds.${system}) packages;
    };
    ordinaryRoots = lib.concatMap (owner: let
      claim = owner.contributions.overlay;
      imported = import claim.source;
      contribution =
        if builtins.isFunction imported
        then imported context
        else imported;
    in
      if claim == null
      then []
      else map builtins.head contribution.claims)
    index.owners;
    guard = import ./unfree-guard.nix final;
    world = facets.realizeOverlay {
      inherit context index;
      packageWorld = packageWorlds.${system};
    };
    # Guard only owned package leaves; namespace neighbors may already have
    # been guarded by another overlay and must not acquire a second wrapper.
    guarded = lib.updateManyAttrsByPath (map (claim: {
        path = claim.keyPath;
        update = guard;
      })
      packageWorlds.${system}.eligibleClaims) (world.overlay final prev);
  in
    lib.genAttrs (lib.unique (packageRoots ++ ordinaryRoots)) (name: guarded.${name} or (prev.${name} or {}));
  checksFor = {rootModules ? [], ...} @ context: let
    world = facets.realizeChecks {
      inherit index rootModules;
      rootSource = root + "/checks";
      context =
        builtins.removeAttrs context ["rootModules"]
        // {
          inherit gitToolExtraction inputs lib;
          harness = import ../testing/module-harness.nix {
            inherit lib;
            inherit (context) pkgs;
            inherit (world) testing;
            moduleImports = backend: facets.moduleImports {inherit backend index;};
          };
        };
    };
  in
    world.checks;
  moduleImports = backend: facets.moduleImports {inherit backend index;};
}
