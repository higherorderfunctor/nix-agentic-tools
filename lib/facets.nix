{lib}: let
  inherit (builtins) attrNames deepSeq isAttrs isFunction length pathExists readDir;
  inherit
    (lib)
    all
    concatMap
    concatStringsSep
    elem
    filter
    foldl'
    genAttrs
    hasSuffix
    mapAttrs
    optionalAttrs
    removeSuffix
    unique
    ;

  sortNames = builtins.sort builtins.lessThan;
  validName = name: builtins.match "[a-z][a-z0-9-]*" name != null;
  ensure = condition: message:
    if condition
    then true
    else throw "facet discovery error: ${message}";

  collision = registry: keyPath: left: right:
    throw ''
      facet collision in ${registry} at '${concatStringsSep "." keyPath}':
        ${left.owner} (${toString left.source})
        ${right.owner} (${toString right.source})
    '';

  mergeFlatClaims = registry: claims:
    foldl' (
      merged: claim:
        if merged ? ${claim.key}
        then collision registry [claim.key] merged.${claim.key} claim
        else merged // {${claim.key} = claim;}
    ) {}
    claims;

  isMergeable = value: isAttrs value && !lib.isDerivation value;
  emptyTree = {
    children = {};
    kind = "root";
  };
  isLeaf = node: node.kind == "leaf";
  isRoot = node: node.kind == "root";

  toClaimTree = claim: value:
    if isMergeable value
    then {
      inherit (claim) owner source;
      children = mapAttrs (_: nested: toClaimTree claim nested) value;
      kind = "branch";
    }
    else {
      inherit (claim) owner source;
      inherit value;
      kind = "leaf";
    };

  mergeTrees = registry: keyPath: left: right:
    if isRoot left
    then right
    else if isRoot right
    then left
    else if isLeaf left || isLeaf right
    then collision registry keyPath left right
    else let
      names = sortNames (unique ((attrNames left.children) ++ (attrNames right.children)));
    in {
      inherit (left) owner source;
      children = genAttrs names (
        name:
          if left.children ? ${name} && right.children ? ${name}
          then mergeTrees registry (keyPath ++ [name]) left.children.${name} right.children.${name}
          else left.children.${name} or right.children.${name}
      );
      kind = "branch";
    };

  materializeTree = tree:
    if isLeaf tree
    then tree.value
    else mapAttrs (_: materializeTree) tree.children;

  mergeContributions = registry: contributions:
    materializeTree (
      foldl' (
        tree: contribution:
          mergeTrees registry [] tree (toClaimTree contribution contribution.value)
      )
      emptyTree
      contributions
    );

  loadValue = path: args: let
    imported = import path;
  in
    if isFunction imported
    then imported args
    else imported;
in {
  compose = {
    facetsDir,
    pkgs,
    registryModules ? [],
    specialArgs ? {
      common = {};
      devenv = {};
      homeManager = {};
    },
    system,
  }: let
    rootEntries = readDir facetsDir;
    ownerNames = sortNames (attrNames rootEntries);
    allowedTopLevel = [
      "README.md"
      "checks.nix"
      "docs"
      "lib.nix"
      "modules"
      "overlay.nix"
      "packages"
      "registry.nix"
      "src"
    ];

    scanOwner = name: let
      root = facetsDir + "/${name}";
      entries = readDir root;
      entryNames = sortNames (attrNames entries);
      unknownEntries = filter (entry: !elem entry allowedTopLevel) entryNames;
      pathFor = entry: root + "/${entry}";
      present = entry: entries ? ${entry};
      regularContribution = entry:
        if present entry
        then pathFor entry
        else null;

      packagesPath = pathFor "packages";
      packageEntries =
        if present "packages"
        then readDir packagesPath
        else {};
      packageFileNames = sortNames (attrNames packageEntries);
      packageClaims =
        map (
          fileName: {
            key = removeSuffix ".nix" fileName;
            owner = name;
            source = packagesPath + "/${fileName}";
          }
        )
        packageFileNames;

      modulesPath = pathFor "modules";
      moduleEntries =
        if present "modules"
        then readDir modulesPath
        else {};
      moduleNames = sortNames (attrNames moduleEntries);
      unknownModules = filter (moduleName: !elem moduleName ["devenv.nix" "homeManager.nix"]) moduleNames;
      invalidRegularEntries = filter (entry: entries.${entry} != "regular") (filter (entry: elem entry ["README.md" "checks.nix" "lib.nix" "overlay.nix" "registry.nix"]) entryNames);
      invalidContainerEntries = filter (entry: entries.${entry} != "directory") (filter (entry: elem entry ["docs" "modules" "packages" "src"]) entryNames);
      invalidPackageEntries = filter (fileName: packageEntries.${fileName} != "regular" || !hasSuffix ".nix" fileName || !validName (removeSuffix ".nix" fileName)) packageFileNames;
      invalidModuleEntries = filter (moduleName: moduleEntries.${moduleName} != "regular") moduleNames;

      fileContributions = filter (value: value != null) [
        (regularContribution "checks.nix")
        (regularContribution "lib.nix")
        (regularContribution "overlay.nix")
        (regularContribution "registry.nix")
      ];
      contributionCount = length packageClaims + length moduleNames + length fileContributions;

      validations = [
        (ensure (unknownEntries == []) "owner '${name}' at '${toString root}' has unknown entry '${toString (pathFor (builtins.head unknownEntries))}'; allowed forms: ${concatStringsSep ", " allowedTopLevel}")
        (ensure (invalidRegularEntries == []) "owner '${name}' at '${toString root}' has non-regular contribution '${toString (pathFor (builtins.head invalidRegularEntries))}'; allowed forms require regular Nix/README files")
        (ensure (invalidContainerEntries == []) "owner '${name}' at '${toString root}' has non-directory contribution container '${toString (pathFor (builtins.head invalidContainerEntries))}'; allowed forms require directories")
        (ensure (invalidPackageEntries == []) "owner '${name}' has invalid package entry '${toString (packagesPath + "/${builtins.head invalidPackageEntries}")}'; allowed forms: regular <export>.nix files with lowercase kebab-case names")
        (ensure (unknownModules == []) "owner '${name}' has unknown module '${toString (modulesPath + "/${builtins.head unknownModules}")}'; allowed forms: devenv.nix, homeManager.nix")
        (ensure (invalidModuleEntries == []) "owner '${name}' has non-regular module '${toString (modulesPath + "/${builtins.head invalidModuleEntries}")}'; allowed forms require regular Nix files")
        (ensure (contributionCount > 0) "owner '${name}' at '${toString root}' is empty or documentation-only; allowed forms require at least one facet contribution")
      ];

      modulePaths = genAttrs moduleNames (moduleName: modulesPath + "/${moduleName}");
      contributions =
        optionalAttrs (present "checks.nix") {checks = pathFor "checks.nix";}
        // optionalAttrs (present "lib.nix") {lib = pathFor "lib.nix";}
        // optionalAttrs (moduleNames != []) {modules = modulePaths;}
        // optionalAttrs (present "overlay.nix") {overlay = pathFor "overlay.nix";}
        // optionalAttrs (packageClaims != []) {packages = map (claim: claim.source) packageClaims;}
        // optionalAttrs (present "registry.nix") {registry = pathFor "registry.nix";};
    in
      deepSeq validations {
        inherit contributions modulePaths name packageClaims root;
        checksPath = regularContribution "checks.nix";
        libPath = regularContribution "lib.nix";
        overlayPath = regularContribution "overlay.nix";
        registryPath = regularContribution "registry.nix";
      };

    rootValidations = [
      (ensure (pathExists facetsDir) "facets directory '${toString facetsDir}' does not exist")
      (ensure (all (name: rootEntries.${name} == "directory") ownerNames) "facets directory '${toString facetsDir}' contains non-directory owner entry '${toString (facetsDir + "/${builtins.head (filter (name: rootEntries.${name} != "directory") ownerNames)}")}'; allowed forms: immediate owner directories")
      (ensure (all validName ownerNames) "invalid owner '${toString (builtins.head (filter (name: !validName name) ownerNames))}' at '${toString (facetsDir + "/${builtins.head (filter (name: !validName name) ownerNames)}")}'; allowed form: [a-z][a-z0-9-]*")
    ];
    ownerData = deepSeq rootValidations (map scanOwner ownerNames);

    owners =
      map (owner: {
        inherit (owner) contributions name;
        path = owner.root;
      })
      ownerData;

    libContributions = map (
      owner: {
        inherit (owner) name;
        owner = owner.name;
        source = owner.libPath;
        value = loadValue owner.libPath {inherit lib pkgs system;};
      }
    ) (filter (owner: owner.libPath != null) ownerData);
    facetLib = mergeContributions "lib" libContributions;

    packageClaims = concatMap (owner: owner.packageClaims) ownerData;
    packageClaimsByName = mergeFlatClaims "packages" packageClaims;
    packageNames = sortNames (attrNames packageClaimsByName);
    packageScope = lib.makeScope pkgs.newScope (
      scope:
        {
          inherit facetLib pkgs system;
        }
        // genAttrs packageNames (
          packageName: scope.callPackage packageClaimsByName.${packageName}.source {}
        )
    );
    packages = genAttrs packageNames (packageName: packageScope.${packageName});

    overlayClaims = map (
      owner: {
        owner = owner.name;
        source = owner.overlayPath;
        value = import owner.overlayPath;
      }
    ) (filter (owner: owner.overlayPath != null) ownerData);
    overlay = final: prev: let
      state =
        foldl' (
          state: claim: let
            contribution = claim.value final state.prev;
            tree = mergeTrees "overlay" [] state.tree (toClaimTree claim contribution);
          in {
            inherit tree;
            prev = state.prev // contribution;
          }
        ) {
          tree = emptyTree;
          inherit prev;
        }
        overlayClaims;
    in
      materializeTree state.tree;

    registryClaims = map (
      owner: {
        owner = owner.name;
        source = owner.registryPath;
      }
    ) (filter (owner: owner.registryPath != null) ownerData);
    registryContributionModules =
      map (
        claim: moduleArgs: let
          imported = import claim.source;
        in
          if isFunction imported
          then
            imported (
              moduleArgs
              // {
                inherit (claim) owner source;
              }
            )
          else imported
      )
      registryClaims;
    registry =
      (lib.evalModules {
        modules = registryModules ++ registryContributionModules;
        specialArgs = specialArgs.common;
      })
      .config;

    modulePathsFor = backend:
      map (owner: owner.modulePaths.${backend}) (filter (owner: owner.modulePaths ? ${backend}) ownerData);
    evalBackend = backend:
      lib.evalModules {
        modules = modulePathsFor "${backend}.nix";
        specialArgs = specialArgs.common // specialArgs.${backend};
      };
    homeManager = evalBackend "homeManager";
    devenv = evalBackend "devenv";

    coreWorld = {
      inherit devenv facetLib homeManager overlay owners packages registry;
    };
    checkClaims =
      concatMap (
        owner:
          if owner.checksPath == null
          then []
          else let
            checks = loadValue owner.checksPath {
              inherit lib pkgs system;
              world = coreWorld;
            };
            checkNames = sortNames (attrNames checks);
          in
            deepSeq (ensure (isAttrs checks) "owner '${owner.name}' checks at '${toString owner.checksPath}' must return an attribute set") (map (
                key: {
                  inherit key;
                  owner = owner.name;
                  source = owner.checksPath;
                  value = checks.${key};
                }
              )
              checkNames)
      )
      ownerData;
    localChecks = mapAttrs (_: claim: {
      inherit (claim) owner source value;
    }) (mergeFlatClaims "checks" checkClaims);
  in {
    inherit devenv facetLib homeManager localChecks overlay owners packages registry;
  };
}
