{lib}: let
  inherit (builtins) attrNames deepSeq isAttrs isFunction length pathExists readDir;
  inherit
    (lib)
    attrByPath
    attrValues
    concatMap
    concatStringsSep
    elem
    filter
    foldl'
    genAttrs
    hasSuffix
    isDerivation
    listToAttrs
    makeScope
    nameValuePair
    optional
    sort
    unique
    ;

  sortNames = sort builtins.lessThan;
  validName = name: builtins.match "[a-z][a-z0-9-]*" name != null;
  ensure = condition: message:
    if condition
    then true
    else throw "facet error: ${message}";

  collision = registry: keyPath: left: right:
    throw ''
      facet ownership collision in ${registry} at '${concatStringsSep "." keyPath}':
        ${left.owner} (${toString left.source})
        ${right.owner} (${toString right.source})
    '';

  pathIsPrefix = prefix: path:
    if prefix == []
    then true
    else if path == [] || builtins.head prefix != builtins.head path
    then false
    else pathIsPrefix (builtins.tail prefix) (builtins.tail path);

  mergeExclusiveClaims = registry: claims:
    foldl' (
      merged: claim: let
        id = builtins.toJSON claim.keyPath;
        conflicts = filter (
          existing:
            pathIsPrefix existing.keyPath claim.keyPath
            || pathIsPrefix claim.keyPath existing.keyPath
        ) (attrValues merged);
      in
        if conflicts != []
        then collision registry claim.keyPath (builtins.head conflicts) claim
        else merged // {${id} = claim;}
    ) {}
    claims;

  ordinaryAttrs = value: isAttrs value && !isDerivation value;

  pathsUnder = prefix: value:
    if ordinaryAttrs value
    then let
      names = attrNames value;
    in
      if names == []
      then [prefix]
      else concatMap (name: pathsUnder (prefix ++ [name]) value.${name}) names
    else [prefix];

  valuesEqual = left: right: let
    compared = builtins.tryEval (left == right);
  in
    compared.success && compared.value;

  changedLeafPaths = prefix: beforePresent: before: after:
    if beforePresent && ordinaryAttrs before && ordinaryAttrs after
    then
      concatMap (
        name:
          if after ? ${name}
          then changedLeafPaths (prefix ++ [name]) (before ? ${name}) before.${name} after.${name}
          else pathsUnder (prefix ++ [name]) before.${name}
      ) (unique (attrNames before ++ attrNames after))
    else if beforePresent && valuesEqual before after
    then []
    else pathsUnder prefix after;

  overlayChanges = prev: contribution:
    concatMap (
      name:
        changedLeafPaths [name] (prev ? ${name}) prev.${name} contribution.${name}
    ) (attrNames contribution);

  contributionFor = owner: name: source: {
    inherit (owner) name;
    owner = owner.name;
    inherit source;
  };

  contributionsFor = index: registry:
    concatMap (
      owner: let
        contribution = owner.contributions.${registry};
      in
        if builtins.isList contribution
        then contribution
        else optional (contribution != null) contribution
    )
    index.owners;

  callOwnerModule = claim: args: let
    imported = import claim.source;
    module =
      if isFunction imported
      then
        imported (
          args
          // {
            facetOwner = claim.owner;
            facetSource = claim.source;
          }
        )
      else imported;
  in
    module // {_file = toString claim.source;};
in rec {
  index = {facetsDir}: let
    rootEntries =
      if pathExists facetsDir
      then readDir facetsDir
      else {};
    ownerNames = sortNames (attrNames rootEntries);
    contributionEntryNames = [
      "checks.nix"
      "modules"
      "overlay.nix"
      "packages"
      "registry.nix"
    ];

    scanOwner = name: let
      root = facetsDir + "/${name}";
      entries = readDir root;
      entryNames = sortNames (attrNames entries);
      owner = {inherit name root;};
      pathFor = entry: root + "/${entry}";
      present = entry: entries ? ${entry};

      regularContribution = entry:
        if present entry
        then contributionFor owner entry (pathFor entry)
        else null;

      packagesPath = pathFor "packages";
      packageEntries =
        if present "packages" && entries.packages == "directory"
        then readDir packagesPath
        else {};
      packageNames = sortNames (attrNames packageEntries);
      packageClaims =
        map (
          packageName: let
            directory = packagesPath + "/${packageName}";
            packageFiles =
              if packageEntries.${packageName} == "directory"
              then readDir directory
              else {};
            source = directory + "/package.nix";
            platformsSource = directory + "/platforms.nix";
          in {
            inherit directory packageName source;
            keyPath = [packageName];
            owner = name;
            platforms =
              if packageFiles ? "platforms.nix"
              then platformsSource
              else null;
            validations = [
              (ensure (validName packageName) "owner '${name}' has invalid package name '${packageName}' at '${toString directory}'; expected lowercase kebab-case")
              (ensure (packageEntries.${packageName} == "directory") "owner '${name}' package '${packageName}' at '${toString directory}' must be a directory")
              (ensure (packageFiles ? "package.nix" && packageFiles."package.nix" == "regular") "owner '${name}' package '${packageName}' is missing regular recipe '${toString source}'")
              (ensure (!(packageFiles ? "platforms.nix") || packageFiles."platforms.nix" == "regular") "owner '${name}' package '${packageName}' has non-regular platform metadata '${toString platformsSource}'")
            ];
          }
        )
        packageNames;

      modulesPath = pathFor "modules";
      moduleEntries =
        if present "modules" && entries.modules == "directory"
        then readDir modulesPath
        else {};
      moduleNames = sortNames (attrNames moduleEntries);
      unknownModules = filter (moduleName: !elem moduleName ["devenv" "homeManager"]) moduleNames;
      invalidModules = filter (
        moduleName: let
          modulePath = modulesPath + "/${moduleName}";
          moduleFiles =
            if moduleEntries.${moduleName} == "directory"
            then readDir modulePath
            else {};
        in
          moduleEntries.${moduleName}
          != "directory"
          || !(moduleFiles ? "default.nix")
          || moduleFiles."default.nix" != "regular"
      ) (filter (moduleName: elem moduleName ["devenv" "homeManager"]) moduleNames);
      moduleContributions = genAttrs (filter (moduleName: elem moduleName ["devenv" "homeManager"]) moduleNames) (
        moduleName: contributionFor owner moduleName (modulesPath + "/${moduleName}")
      );

      invalidContributionFiles = filter (
        entry: entries.${entry} != "regular"
      ) (filter (entry: elem entry ["checks.nix" "overlay.nix" "registry.nix"]) entryNames);
      invalidContributionDirectories = filter (
        entry: entries.${entry} != "directory"
      ) (filter (entry: elem entry ["modules" "packages"]) entryNames);

      metadataEntries = filter (entry: !elem entry contributionEntryNames) entryNames;
      classifyMetadata = entry: let
        type = entries.${entry};
        kind =
          if type == "directory"
          then
            if elem entry ["docs" "fragments" "src"]
            then entry
            else "directory-sidecar"
          else if type != "regular"
          then "unsupported"
          else if entry == "default.nix"
          then "owner-default"
          else if entry == "README.md" || hasSuffix ".md" entry
          then "documentation"
          else if hasSuffix ".nix" entry
          then "nix-sidecar"
          else if hasSuffix ".json" entry || hasSuffix ".lock" entry || hasSuffix ".toml" entry || hasSuffix ".yaml" entry || hasSuffix ".yml" entry
          then "data-sidecar"
          else "unsupported";
      in {
        inherit kind;
        source = pathFor entry;
      };
      metadata = map classifyMetadata metadataEntries;
      unsupportedMetadata = filter (entry: entry.kind == "unsupported") metadata;

      contributions = {
        checks = regularContribution "checks.nix";
        modules = moduleContributions;
        overlay = regularContribution "overlay.nix";
        packages =
          map (
            claim:
              builtins.removeAttrs claim ["packageName" "validations"]
          )
          packageClaims;
        registry = regularContribution "registry.nix";
      };
      contributionCount =
        length contributions.packages
        + length (attrNames contributions.modules)
        + length (filter (value: value != null) [contributions.checks contributions.overlay contributions.registry]);
      validations =
        [
          (ensure (invalidContributionFiles == []) "owner '${name}' has non-regular contribution '${toString (pathFor (builtins.head invalidContributionFiles))}'")
          (ensure (invalidContributionDirectories == []) "owner '${name}' has non-directory contribution container '${toString (pathFor (builtins.head invalidContributionDirectories))}'")
          (ensure (unknownModules == []) "owner '${name}' has unknown module entry '${toString (modulesPath + "/${builtins.head unknownModules}")}'; expected directory-shaped devenv or homeManager modules")
          (ensure (invalidModules == []) "owner '${name}' module '${toString (modulesPath + "/${builtins.head invalidModules}")}' must be a directory with regular default.nix")
          (ensure (unsupportedMetadata == []) "owner '${name}' has unclassified metadata '${toString (builtins.head unsupportedMetadata).source}'")
          (ensure (contributionCount > 0) "owner '${name}' at '${toString root}' is metadata-only; at least one exported contribution is required")
        ]
        ++ concatMap (claim: claim.validations) packageClaims;
    in
      deepSeq validations {
        inherit contributions metadata name;
        path = root;
      };

    invalidRootEntries = filter (name: rootEntries.${name} != "directory") ownerNames;
    invalidOwnerNames = filter (name: !validName name) ownerNames;
    rootValidations = [
      (ensure (pathExists facetsDir) "facets directory '${toString facetsDir}' does not exist")
      (ensure (invalidRootEntries == []) "facets directory '${toString facetsDir}' contains non-directory owner '${toString (facetsDir + "/${builtins.head invalidRootEntries}")}'")
      (ensure (invalidOwnerNames == []) "invalid owner '${builtins.head invalidOwnerNames}' at '${toString (facetsDir + "/${builtins.head invalidOwnerNames}")}'; expected lowercase kebab-case")
    ];
  in
    deepSeq rootValidations {
      inherit facetsDir;
      owners = map scanOwner ownerNames;
    };

  moduleImports = {
    backend,
    index,
  }:
    map (
      owner: owner.contributions.modules.${backend}.source
    ) (filter (owner: owner.contributions.modules ? ${backend}) index.owners);

  realizePackages = {
    index,
    inputs,
    pkgs,
    scopeArgs ? {},
    system,
  }: let
    claims = contributionsFor index "packages";
    injectedArgs =
      scopeArgs
      // {
        inherit inputs pkgs system;
      };
    nativeScopeMembers = attrNames (makeScope pkgs.newScope (_: {}));
    reservedNames = unique (nativeScopeMembers ++ attrNames injectedArgs);
    reservedClaims = filter (claim: elem (builtins.head claim.keyPath) reservedNames) claims;
    exclusive = mergeExclusiveClaims "packages" claims;
    eligibleClaims =
      filter (
        claim:
          claim.platforms
          == null
          || elem system (import claim.platforms)
      )
      claims;
    scope = makeScope pkgs.newScope (
      self:
        injectedArgs
        // listToAttrs (map (
            claim:
              nameValuePair (builtins.head claim.keyPath) (
                lib.filesystem.packagesFromDirectoryRecursive {
                  inherit (claim) directory;
                  inherit (self) callPackage;
                }
              )
          )
          eligibleClaims)
    );
    packageNames = map (claim: builtins.head claim.keyPath) eligibleClaims;
    validations = [
      (ensure (reservedClaims == []) "reserved package name '${builtins.head (builtins.head reservedClaims).keyPath}' from owner '${(builtins.head reservedClaims).owner}' at '${toString (builtins.head reservedClaims).source}' would overwrite a native or injected scope member")
    ];
  in
    deepSeq [exclusive validations] {
      inherit claims scope;
      omitted = map (claim: builtins.head claim.keyPath) (filter (claim: !elem claim eligibleClaims) claims);
      packages = genAttrs packageNames (name: scope.${name});
    };

  realizeOverlay = {
    context,
    index,
  }: let
    sourceClaims = contributionsFor index "overlay";
    loaded =
      map (
        claim: let
          factory = import claim.source;
          value =
            if isFunction factory
            then factory context
            else factory;
          claimValidations = [
            (ensure (isAttrs value && value ? claims && value ? overlay) "owner '${claim.owner}' overlay at '${toString claim.source}' must return { claims, overlay }")
            (ensure (isAttrs value && value ? claims && builtins.isList value.claims) "owner '${claim.owner}' overlay claims at '${toString claim.source}' must be a list of exclusive leaf paths")
            (ensure (isAttrs value && value ? overlay && isFunction value.overlay) "owner '${claim.owner}' overlay at '${toString claim.source}' must provide an overlay function")
            (ensure (
              isAttrs value
              && value ? claims
              && builtins.isList value.claims
              && builtins.all (
                keyPath:
                  builtins.isList keyPath
                  && keyPath != []
                  && builtins.all (component: builtins.isString component && component != "") keyPath
              )
              value.claims
            ) "owner '${claim.owner}' overlay claims at '${toString claim.source}' must contain non-empty lists of non-empty strings")
          ];
        in
          deepSeq claimValidations {
            inherit claim value;
          }
      )
      sourceClaims;
    ownershipClaims =
      concatMap (
        loadedClaim:
          map (keyPath: {
            inherit keyPath;
            inherit (loadedClaim.claim) owner source;
          })
          loadedClaim.value.claims
      )
      loaded;
    exclusive = mergeExclusiveClaims "overlay" ownershipClaims;
    checkedOverlays =
      map (
        item: final: prev: let
          contribution = item.value.overlay final prev;
          changedPaths =
            if isAttrs contribution
            then overlayChanges prev contribution
            else [];
          declaredIds = map builtins.toJSON item.value.claims;
          changedIds = map builtins.toJSON changedPaths;
          undeclared = filter (path: !elem (builtins.toJSON path) declaredIds) changedPaths;
          unwritten = filter (path: !elem (builtins.toJSON path) changedIds) item.value.claims;
          validations = [
            (ensure (isAttrs contribution) "owner '${item.claim.owner}' overlay at '${toString item.claim.source}' must return an attribute set")
            (ensure (undeclared == []) "owner '${item.claim.owner}' overlay at '${toString item.claim.source}' writes undeclared leaf '${concatStringsSep "." (builtins.head undeclared)}'")
            (ensure (unwritten == []) "owner '${item.claim.owner}' overlay at '${toString item.claim.source}' claims unwritten leaf '${concatStringsSep "." (builtins.head unwritten)}'")
          ];
        in
          deepSeq validations contribution
      )
      loaded;
  in
    deepSeq exclusive {
      inherit ownershipClaims;
      overlay = lib.composeManyExtensions checkedOverlays;
    };

  realizeRegistry = {
    claimPath,
    index,
    modules,
    specialArgs ? {},
  }: let
    sourceClaims = contributionsFor index "registry";
    ownerModules =
      map (
        claim: args: callOwnerModule claim args
      )
      sourceClaims;
    evaluate = extraModules:
      lib.evalModules {
        inherit specialArgs;
        modules = modules ++ extraModules;
      };
    rootKeys = attrNames (attrByPath claimPath {} (evaluate []).config);
    ownershipClaims =
      concatMap (
        claim: let
          evaluated = evaluate [(args: callOwnerModule claim args)];
          values = attrByPath claimPath {} evaluated.config;
        in
          map (key: {
            keyPath = claimPath ++ [key];
            inherit (claim) owner source;
          }) (filter (key: !elem key rootKeys) (attrNames values))
      )
      sourceClaims;
    exclusive = mergeExclusiveClaims "registry" ownershipClaims;
    evaluated = evaluate ownerModules;
  in
    deepSeq exclusive {
      inherit (evaluated) config;
      inherit evaluated ownershipClaims;
    };

  realizeChecks = {
    context,
    index,
  }: let
    sourceClaims = contributionsFor index "checks";
    checkClaims =
      concatMap (
        claim: let
          factory = import claim.source;
          checks =
            if isFunction factory
            then factory context
            else throw "facet error: owner '${claim.owner}' check at '${toString claim.source}' must be a context factory";
          checkNames =
            if isAttrs checks
            then sortNames (attrNames checks)
            else throw "facet error: owner '${claim.owner}' check factory at '${toString claim.source}' must return an attribute set";
        in
          map (name: {
            keyPath = [name];
            inherit (claim) owner source;
            value = checks.${name};
          })
          checkNames
      )
      sourceClaims;
    exclusive = mergeExclusiveClaims "checks" checkClaims;
    nonDerivations = filter (claim: !isDerivation claim.value) checkClaims;
    validations = [
      (ensure (nonDerivations == []) "owner '${(builtins.head nonDerivations).owner}' check '${builtins.head (builtins.head nonDerivations).keyPath}' at '${toString (builtins.head nonDerivations).source}' returned a non-derivation")
    ];
    checksByName = listToAttrs (map (
        claim:
          nameValuePair (builtins.head claim.keyPath) {
            inherit (claim) owner source value;
          }
      )
      checkClaims);
  in
    deepSeq [(attrNames exclusive) validations] checksByName;
}
