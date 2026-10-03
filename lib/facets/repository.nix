{
  inputs,
  registryModules ? null,
  root,
}: let
  inherit (inputs.nixpkgs) lib;
  facets = import ../facets.nix {inherit lib;};
  registry =
    import ./registry.nix ({inherit lib root;}
      // lib.optionalAttrs (registryModules != null) {modules = registryModules;});
  inherit (registry) index repoPath;
  inherit (registry.config) update;
  # The git tools' census builder, handed to owner packages and checks as an
  # argument so an owner never reaches into lib/ by a relative path (the
  # facet-owner-relocation check moves an owner and re-evaluates it).
  gitToolExtraction = import ../git-tool-settings/extraction.nix;
  packageWorldFor = pkgs: let
    system = pkgs.stdenv.hostPlatform.system;
  in
    facets.realizePackages {
      inherit index inputs pkgs system;
      scopeArgs = {
        inherit gitToolExtraction repoPath;
        packageLib = import ../packaging.nix // import ../toolchains.nix {inherit inputs;};
        fragmentsLib = import ../fragments.nix {inherit lib;};
        # `generatedLib pkgs`: the builder generated files are formatted in.
        generatedLib = import ../generated.nix {inherit lib;};
        traceSource = import ../traceSource.nix {inherit lib;};
      };
    };
  # Overlay attribute names must be available before the nixpkgs fixed point
  # can supply stdenv/system. Discover the outer namespace without realization.
  packageRoots =
    lib.unique (map (claim: builtins.head claim.keyPath)
      (lib.concatMap (owner: owner.contributions.packages) index.owners));
in {
  inherit index repoPath update;
  libraryFor = rootLibrary:
    facets.realizeLibrary {
      inherit index rootLibrary;
      rootSource = root + "/lib";
      context = {inherit inputs lib repoPath;};
    };
  packagesFor = {
    pkgs,
    rootPackages ? {},
  }:
    facets.flattenPackages {
      inherit pkgs rootPackages;
      packageWorld = packageWorldFor pkgs;
      rootSource = root + "/flake.nix";
    };
  overlay = final: prev: let
    system = final.stdenv.hostPlatform.system;
    packageWorld = packageWorldFor final;
    context = {
      inherit inputs lib system;
      inherit (packageWorld) packages;
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
    world = facets.realizeOverlay {
      inherit context index packageWorld;
    };
    composed = world.overlay final prev;
  in
    lib.genAttrs (lib.unique (packageRoots ++ ordinaryRoots)) (name: composed.${name} or (prev.${name} or {}));
  checksFor = {rootModules ? [], ...} @ context: let
    world = facets.realizeChecks {
      inherit index rootModules;
      rootSource = root + "/checks";
      context =
        builtins.removeAttrs context ["rootModules"]
        // {
          inherit gitToolExtraction inputs lib;
          harness = import ../testing/module-harness.nix {
            inherit inputs lib;
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
