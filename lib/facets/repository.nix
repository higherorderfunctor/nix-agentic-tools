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
  rootNamesFor = context: lib.unique (packageRoots ++ map builtins.head (ordinaryClaimsFor context));
  supportedSystems = import ../../config/systems.nix;
  ordinaryAttrs = value: builtins.isAttrs value && !lib.isDerivation value;
  # The recipe-level overlay: builds every claimed package on whatever `final`
  # it is given. It builds this flake's own package sets (natSets), the
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
    lib.genAttrs (rootNamesFor context) (name: composed.${name} or (prev.${name} or {}));
  # This flake's one package set per supported system: its own nixpkgs with
  # buildOverlay. `allowUnfree` only lets every leaf evaluate here, for CI and
  # checks. No consumer config reaches it, and nothing from it is handed out
  # without `checkedBy`, which puts each derivation under the receiver's own
  # meta checks.
  natSets = lib.genAttrs supportedSystems (system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [buildOverlay];
    });
  # `checkedBy pkgs value` hands `value` out under `pkgs`' own meta checks.
  # Each derivation in it, recursing lazily through attrsets that are not
  # derivations, keeps its drvPath, outPath and passthru, but its drvPath and
  # outPath first assert a probe, a never-built `pkgs.stdenvNoCC.mkDerivation`
  # with the derivation's name, pname, version, outputs and meta. So the receiver's
  # nixpkgs, with its own config and key names, decides unfree, broken,
  # insecure and platform, and refuses with nixpkgs' own message. Nothing here
  # names a config key, and nixpkgs' check-meta internals are never imported.
  #
  # `meta.available` answers without instantiating the probe (measured: no
  # .drv written; forcing the probe's drvPath writes one and instantiates
  # stdenvNoCC). Only an unavailable probe forces drvPath, whose own assertion
  # throws nixpkgs' refusal before anything is instantiated. Consumer-configured
  # warn-level problems are not shown for an available probe.
  #
  # `.override`, `.overrideAttrs` and `.overrideDerivation` results are checked
  # again, so a consumer's rebuild of an unfree package still needs the
  # opt-in. Other passthru functions (`mkSkill`, ...) return unchecked
  # derivations. `meta.available` is the probe's, so a consumer filtering on
  # it sees the receiver's verdict rather than this flake's `allowUnfree` one.
  #
  # The receiver's predicates (`allowUnfreePredicate`, ...) are handed the
  # probe, which carries name, pname, version and meta; one that reads any
  # other attribute (`src`, ...) does not see it.
  checkedBy = pkgs: let
    check = value:
      if lib.isDerivation value
      then let
        # `outputs` too, so `meta.outputsToInstall` stays valid under the
        # receiver's `checkMeta`.
        probe = pkgs.stdenvNoCC.mkDerivation ({
            inherit (value) name;
            meta = value.meta or {};
            outputs = value.outputs or ["out"];
          }
          // lib.optionalAttrs (value ? pname) {inherit (value) pname;}
          // lib.optionalAttrs (value ? version) {inherit (value) version;});
        valid = probe.meta.available or false || builtins.seq probe.drvPath true;
        recheck = name:
          lib.optionalAttrs (value ? ${name}) {
            ${name} = lib.mirrorFunctionArgs value.${name} (argument: check (value.${name} argument));
          };
      in
        lib.extendDerivation valid (recheck "override"
          // recheck "overrideAttrs"
          // recheck "overrideDerivation"
          // {
            meta = (value.meta or {}) // lib.optionalAttrs (probe.meta ? available) {inherit (probe.meta) available;};
          })
        value
      else if ordinaryAttrs value
      then builtins.mapAttrs (_: check) value
      else value;
  in
    check;
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
  # Every root this flake's packages claim (`ai`, `docs`, ...) for `pkgs`: the
  # consumer's own root when the overlay is applied (so a consumer's override
  # flows), else this flake's build checked by `pkgs`. Module sites read these,
  # never a root of their raw `pkgs`. The fallback builds on `pkgs` itself,
  # whose mkDerivation already checks.
  rootsFor = pkgs: let
    system = natSystemOf pkgs;
    fallback = pkgs.extend buildOverlay;
    rootOf = root:
      if system == null
      then fallback.${root}
      else checkedBy pkgs natSets.${system}.${root};
  in
    lib.genAttrs packageRoots (root: pkgs.${root} or (rootOf root));
  # Flake values the exported modules receive as `ai.internal`.
  moduleInternals = {
    inherit rootsFor;
    treefmtNix = inputs.treefmt-nix;
  };
in {
  inherit buildOverlay checkedBy claimedPaths index moduleInternals natSets natSystemOf repoPath rootsFor supportedSystems update;
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
    namespaceRoots = builtins.filter (name: !lib.elem name leafRoots) (rootNamesFor {
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
  # builds from natSets rather than rebuilding on the consumer's `final`, so
  # overlay and module defaults hit the cache whatever nixpkgs the consumer
  # uses. Each leaf is checkedBy `final`, so the consumer's own nixpkgs decides
  # whether it evaluates. Where natSystemOf returns null (unsupported system,
  # cross, non-default libc) it falls back to buildOverlay on `final`, whose
  # mkDerivation checks on its own. The fallback choice is made per value:
  # deciding it at the top level would recurse through `final.stdenv`.
  overlay = final: prev: let
    system = natSystemOf final;
    natSet = natSets.${system};
    check = checkedBy final;
    context = {
      inherit inputs lib system;
      inherit (packageWorldFor natSet) packages;
    };
    tree =
      lib.foldl' (
        acc: keyPath: lib.recursiveUpdate acc (lib.setAttrByPath keyPath (check (lib.getAttrFromPath keyPath natSet)))
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
    lib.genAttrs (rootNamesFor context) (name:
      if system == null
      then built.${name}
      else reexported.${name} or (prev.${name} or {}));
  checksFor = {rootModules ? [], ...} @ context: let
    # The module harness over any package set; `harness` is it over the
    # checks' own. The overlay parity gate re-instantiates it over a foreign
    # nixpkgs with `injectAi = false`.
    harnessFor = args:
      import ../testing/module-harness.nix ({
          inherit inputs lib moduleInternals;
          inherit (context) pkgs;
          inherit (world) testing;
          moduleImports = backend: facets.moduleImports {inherit backend index;};
        }
        // args);
    world = facets.realizeChecks {
      inherit index rootModules;
      rootSource = root + "/checks";
      context =
        builtins.removeAttrs context ["rootModules"]
        // {
          inherit buildOverlay gitToolExtraction harnessFor inputs lib natSystemOf rootsFor;
          # The leaf paths the exported overlay re-exports on this system.
          claimedPaths = claimedPaths {
            inherit inputs lib;
            inherit (packageWorldFor context.pkgs) packages;
            system = context.pkgs.stdenv.hostPlatform.system;
          };
          harness = harnessFor {};
        };
    };
  in
    world.checks;
  moduleImports = backend: facets.moduleImports {inherit backend index;};
}
