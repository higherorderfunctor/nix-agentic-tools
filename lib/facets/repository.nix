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
  # Leaf paths claimed by owner overlay.nix contributions (none in production
  # today). Only `claims` is read, so `context` stays lazy.
  ordinaryClaimsFor = context:
    lib.concatMap (owner: let
      claim = owner.contributions.overlay;
      imported = import claim.source;
      contribution =
        if builtins.isFunction imported
        then imported context
        else imported;
    in
      if claim == null
      then []
      else contribution.claims)
    index.owners;
  # Overlay attribute names. They must not depend on `final`'s values: the
  # nixpkgs fixed point needs them before it can supply stdenv or system.
  rootsFor = context: lib.unique (packageRoots ++ map builtins.head (ordinaryClaimsFor context));
  supportedSystems = import ../../config/systems.nix;
  ordinaryAttrs = value: builtins.isAttrs value && !lib.isDerivation value;
  # The recipe-level overlay: builds every claimed package on whatever `final`
  # it is given. It builds this flake's own package sets (natSetFor), the
  # repository's devenv shell, and the exported overlay's fallback.
  buildOverlay = final: prev: let
    system = final.stdenv.hostPlatform.system;
    packageWorld = packageWorldFor final;
    context = {
      inherit inputs lib system;
      inherit (packageWorld) packages;
    };
    world = facets.realizeOverlay {
      inherit context index packageWorld;
    };
    composed = world.overlay final prev;
  in
    lib.genAttrs (rootsFor context) (name: composed.${name} or (prev.${name} or {}));
  # Every nixpkgs config key that only gates evaluation (sorted). Each one is
  # read only by nixpkgs' stdenv/generic/{check-meta,problems,remediations}.nix,
  # so forwarding it changes which packages evaluate, never a derivation hash.
  # Re-check this list on every nixpkgs bump.
  gateKeys = [
    "allowBroken"
    "allowBrokenPredicate"
    "allowInsecurePredicate"
    "allowNonSource"
    "allowNonSourcePredicate"
    "allowUnfree"
    "allowUnfreePackages"
    "allowUnfreePredicate"
    "allowUnsupportedSystem"
    "allowlistedLicenses"
    "blacklistedLicenses"
    "blocklistedLicenses"
    "permittedInsecurePackages"
    "whitelistedLicenses"
  ];
  # Copy only the keys the caller's config actually has, so an older consumer
  # nixpkgs without a key is safe.
  licenseConfig = config: lib.getAttrs (builtins.filter (key: config ? ${key}) gateKeys) config;
  # The one instantiation of this flake's nixpkgs that builds its packages.
  # Every package output, the exported overlay and the module defaults call it;
  # `config` carries only the caller's license gates, so all of them agree on
  # every derivation.
  natSetFor = {
    system,
    config ? {},
  }:
    import inputs.nixpkgs {
      inherit system;
      config = licenseConfig config;
      overlays = [buildOverlay];
    };
  # The supported system `pkgs` targets natively, or null when this flake's
  # builds cannot stand in for it: an unsupported system, a cross build, or a
  # non-default libc/ABI on the same system string (pkgsMusl, pkgsStatic). The
  # test is the platform triple, because the triple is what the cache is keyed
  # to; pkgsLLVM and gcc.arch tuning keep it and so get this flake's build.
  natSystemOf = pkgs: let
    inherit (pkgs.stdenv) buildPlatform hostPlatform;
    inherit (hostPlatform) system;
    native = (lib.systems.elaborate system).config;
  in
    if lib.elem system supportedSystems && buildPlatform.config == native && hostPlatform.config == native
    then system
    else null;
  # Leaf paths the exported overlay re-exports for `system`: every package
  # claim built there plus every owner overlay claim.
  claimedPaths = context:
    map (claim: claim.keyPath) (facets.eligibleClaimsFor {
      inherit index;
      inherit (context) system;
    })
    ++ ordinaryClaimsFor context;
  # This flake's package tree for `pkgs`: its own `ai` when the overlay is
  # applied (so a consumer's override flows), else this flake's build.
  aiFor = pkgs:
    pkgs.ai or (
      let
        system = natSystemOf pkgs;
      in
        if system == null
        then (pkgs.extend buildOverlay).ai
        else
          (natSetFor {
            inherit system;
            config = pkgs.config or {};
          }).ai
    );
  # Flake values the exported modules receive as `ai.internal`.
  moduleInternals = {
    packagesFor = aiFor;
    treefmtNix = inputs.treefmt-nix;
  };
in {
  inherit aiFor buildOverlay claimedPaths gateKeys index moduleInternals natSetFor natSystemOf repoPath supportedSystems update;
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
  # One rule for legacyPackages: every leaf under its basename, and every
  # namespace root (`ai`, `docs`, ...) nested. The roots go through the same
  # exclusive merge, so a leaf named like a root fails instead of shadowing it.
  # Roots that are themselves leaves are already in the flat set.
  legacyPackagesFor = pkgs: let
    packageWorld = packageWorldFor pkgs;
    leafRoots = map (claim: builtins.head claim.keyPath) (builtins.filter (claim: builtins.length claim.keyPath == 1) packageWorld.eligibleClaims);
    namespaceRoots = builtins.filter (name: !lib.elem name leafRoots) (rootsFor {
      inherit inputs lib packageWorld;
      inherit (packageWorld) packages;
      system = pkgs.stdenv.hostPlatform.system;
    });
  in
    facets.flattenPackages {
      inherit packageWorld pkgs;
      rootPackages = lib.genAttrs namespaceRoots (name: pkgs.${name});
      rootSource = root + "/flake.nix";
    };
  # The exported overlay (overlays.default). It re-exports this flake's own
  # builds from natSetFor rather than rebuilding on the consumer's `final`, so
  # overlay and module defaults hit the cache whatever nixpkgs the consumer
  # uses. Only the consumer's license gates reach natSetFor. Where natSystemOf
  # returns null (unsupported system, cross, non-default libc) it falls back to
  # buildOverlay on `final`. The fallback choice is made per value: deciding
  # it at the top level would recurse through `final.stdenv`.
  overlay = final: prev: let
    system = natSystemOf final;
    natSet = natSetFor {
      inherit system;
      config = final.config or {};
    };
    context = {
      inherit inputs lib system;
      inherit (packageWorldFor natSet) packages;
    };
    tree =
      lib.foldl' (
        acc: keyPath: lib.recursiveUpdate acc (lib.setAttrByPath keyPath (lib.getAttrFromPath keyPath natSet))
      ) {}
      (claimedPaths context);
    # Same merge as facets.realizeOverlay: keep the consumer's neighbours in a
    # shared namespace, replace only the claimed leaves.
    reexported =
      lib.recursiveUpdateUntil (_: before: after: !(ordinaryAttrs before && ordinaryAttrs after))
      prev
      tree;
    built = buildOverlay final prev;
  in
    lib.genAttrs (rootsFor context) (name:
      if system == null
      then built.${name}
      else reexported.${name} or (prev.${name} or {}));
  checksFor = {rootModules ? [], ...} @ context: let
    world = facets.realizeChecks {
      inherit index rootModules;
      rootSource = root + "/checks";
      context =
        builtins.removeAttrs context ["rootModules"]
        // {
          inherit buildOverlay gitToolExtraction inputs lib;
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
