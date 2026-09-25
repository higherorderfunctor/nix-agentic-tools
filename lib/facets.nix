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
      facet ownership collision in ${registry} at '${lib.showAttrPath keyPath}':
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
        contains = parent: child:
          (parent.kind or "")
          == "namespace"
          && pathIsPrefix parent.keyPath child.keyPath
          && (parent.keyPath != child.keyPath || (child.kind or "") == "namespace");
        conflicts = filter (
          existing:
            (pathIsPrefix existing.keyPath claim.keyPath
              || pathIsPrefix claim.keyPath existing.keyPath)
            && !(contains existing claim || contains claim existing)
        ) (attrValues merged);
      in
        if conflicts != []
        then collision registry claim.keyPath (builtins.head conflicts) claim
        else merged // {${id} = claim;}
    ) {}
    claims;

  packageTree = import ./facets/packages.nix {
    inherit lib ensure mergeExclusiveClaims;
  };

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
  # Flake packages must be flat derivations. Validate the lossy projection
  # before constructing its attrset so equal basenames cannot overwrite.
  flattenPackages = {
    packageWorld,
    pkgs,
    rootPackages ? {},
    rootSource ? "<workspace>",
  }: let
    claims = map (claim:
      claim
      // {
        keyPath = [(lib.last claim.keyPath)];
        value = lib.getAttrFromPath claim.keyPath pkgs;
      })
    packageWorld.eligibleClaims;
    rootClaims =
      lib.mapAttrsToList (name: value: {
        keyPath = [name];
        owner = "<workspace>";
        source = rootSource;
        inherit value;
      })
      rootPackages;
    exclusive = mergeExclusiveClaims "flat packages" (claims ++ rootClaims);
  in
    builtins.listToAttrs (map (claim: {
      name = builtins.head claim.keyPath;
      inherit (claim) value;
    }) (builtins.attrValues exclusive));

  index = {facetsDir}: let
    rootEntries =
      if pathExists facetsDir
      then readDir facetsDir
      else {};
    ownerNames = sortNames (attrNames rootEntries);
    contributionEntryNames = [
      "checks.nix"
      "lib"
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

      libraryPath = pathFor "lib";
      libraryEntries =
        if present "lib" && entries.lib == "directory"
        then readDir libraryPath
        else {};
      libraryContribution =
        if libraryEntries ? "default.nix"
        then contributionFor owner "library" (libraryPath + "/default.nix")
        else null;

      packagesPath = pathFor "packages";
      packageClaims =
        if present "packages" && entries.packages == "directory"
        then packageTree.scan owner packagesPath []
        else [];

      modulesPath = pathFor "modules";
      moduleEntries =
        if present "modules" && entries.modules == "directory"
        then readDir modulesPath
        else {};
      moduleNames = sortNames (attrNames moduleEntries);
      unknownModules = filter (moduleName:
        !elem moduleName ["devenv" "homeManager"]
        && !(moduleEntries.${moduleName} == "regular" && hasSuffix ".nix" moduleName))
      moduleNames;
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
      ) (filter (entry: elem entry ["lib" "modules" "packages"]) entryNames);

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
        library = libraryContribution;
        modules = moduleContributions;
        overlay = regularContribution "overlay.nix";
        packages = packageClaims;
        registry = regularContribution "registry.nix";
      };
      contributionCount =
        length contributions.packages
        + length (attrNames contributions.modules)
        + length (filter (value: value != null) [contributions.checks contributions.library contributions.overlay contributions.registry]);
      validations = [
        (ensure (invalidContributionFiles == []) "owner '${name}' has non-regular contribution '${toString (pathFor (builtins.head invalidContributionFiles))}'")
        (ensure (invalidContributionDirectories == []) "owner '${name}' has non-directory contribution container '${toString (pathFor (builtins.head invalidContributionDirectories))}'")
        (ensure (!(libraryEntries ? "default.nix") || libraryEntries."default.nix" == "regular") "owner '${name}' library '${toString (libraryPath + "/default.nix")}' must be regular")
        (ensure (unknownModules == []) "owner '${name}' has unknown module entry '${toString (modulesPath + "/${builtins.head unknownModules}")}'; expected directory-shaped devenv or homeManager modules")
        (ensure (invalidModules == []) "owner '${name}' module '${toString (modulesPath + "/${builtins.head invalidModules}")}' must be a directory with regular default.nix")
        (ensure (unsupportedMetadata == []) "owner '${name}' has unclassified metadata '${toString (builtins.head unsupportedMetadata).source}'")
        (ensure (contributionCount > 0) "owner '${name}' at '${toString root}' is metadata-only; at least one exported contribution is required")
      ];
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

  realizePackages = packageTree.realize;

  # Native module options merge library namespaces while raw leaf options keep
  # function identity (including functionArgs) intact. types.anything would wrap
  # function values in a merging lambda and erase their argument interface.
  realizeLibrary = {
    context,
    index,
    rootLibrary ? {},
    rootSource ? "<root library>",
  }: let
    # Option types, option declarations and callable attrsets are values, not
    # namespaces. Walking their internals forces deliberately lazy module
    # evaluations (for example a submodule's required, unset options).
    libraryPaths = prefix: value:
      if ordinaryAttrs value && !lib.isOption value && !lib.isOptionType value && !(value ? __functor)
      then let
        names = attrNames value;
      in
        if names == []
        then [prefix]
        else concatMap (name: libraryPaths (prefix ++ [name]) value.${name}) names
      else [prefix];
    sources =
      [
        {
          owner = "<root>";
          source = rootSource;
          value = rootLibrary;
        }
      ]
      ++ map (claim: let
        imported = import claim.source;
      in
        claim
        // {
          value =
            if isFunction imported
            then imported context
            else imported;
        }) (contributionsFor index "library");
    claims = concatMap (claim:
      assert ensure (ordinaryAttrs claim.value) "owner '${claim.owner}' library at '${toString claim.source}' must return an attribute set";
        map (keyPath: {
          inherit keyPath;
          inherit (claim) owner source;
        })
        (
          if claim.value == {}
          then []
          else libraryPaths [] claim.value
        ))
    sources;
    exclusive = mergeExclusiveClaims "library" claims;
    options = foldl' lib.recursiveUpdate {} (map (
        claim:
          lib.setAttrByPath (["exports"] ++ claim.keyPath) (lib.mkOption {type = lib.types.raw;})
      )
      claims);
    evaluated = lib.evalModules {
      modules =
        [{inherit options;}]
        ++ map (claim: {
          _file = toString claim.source;
          config.exports = claim.value;
        }) (filter (claim: claim.value != {}) sources);
    };
  in
    deepSeq exclusive (evaluated.config.exports or {});

  realizeOverlay = {
    context,
    index,
    packageWorld ? null,
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
    packageClaims =
      if packageWorld == null
      then []
      else packageWorld.eligibleClaims;
    ownershipClaims =
      packageClaims
      ++ concatMap (
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
      overlay = lib.composeManyExtensions (
        optional (packageWorld != null) (_final: prev:
          lib.intersectAttrs packageWorld.packages (
            lib.recursiveUpdateUntil (_: before: after: !(ordinaryAttrs before && ordinaryAttrs after))
            prev
            packageWorld.packages
          ))
        ++ checkedOverlays
      );
    };

  realizeRegistry = {
    claimPaths,
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
    evaluate = args: extraModules:
      lib.evalModules {
        specialArgs = args;
        modules = modules ++ extraModules;
      };
    evaluated = evaluate specialArgs ownerModules;
    # Keep contributor definitions separate while their conditions and imported
    # arguments observe the combined fixed point. Otherwise a conditional key
    # can appear only in the final merge and escape ownership validation.
    claimArgs =
      specialArgs
      // {
        config = evaluated.config // {inherit (evaluated) _module;};
        inherit (evaluated) options;
      };
    definitionsFor = claimPath: evaluated:
      (attrByPath claimPath {} evaluated.options).definitionsWithLocations or [];
    rootEvaluation = evaluate claimArgs [];
    rootOwnershipClaims = concatMap (claimPath: let
      definitions = definitionsFor claimPath rootEvaluation;
      keys = unique (concatMap (definition: attrNames definition.value) definitions);
    in
      map (key: let
        definition = builtins.head (filter (candidate: candidate.value ? ${key}) definitions);
      in {
        keyPath = claimPath ++ [key];
        owner = "root policy";
        source = definition.file;
      })
      keys)
    claimPaths;
    ownershipClaims = concatMap (claim: let
      isolated = evaluate claimArgs [(args: callOwnerModule claim args)];
    in
      concatMap (claimPath: let
        rootDefinitions = definitionsFor claimPath rootEvaluation;
        ownerDefinitions = filter (
          definition:
            !builtins.any (
              rootDefinition:
                definition.file
                == rootDefinition.file
                && valuesEqual definition.value rootDefinition.value
            )
            rootDefinitions
        ) (definitionsFor claimPath isolated);
        keys = unique (concatMap (definition: attrNames definition.value) ownerDefinitions);
      in
        map (key: {
          keyPath = claimPath ++ [key];
          inherit (claim) owner source;
        })
        keys)
      claimPaths)
    sourceClaims;
    exclusive = mergeExclusiveClaims "registry" (rootOwnershipClaims ++ ownershipClaims);
  in
    deepSeq exclusive {
      inherit (evaluated) config;
      inherit evaluated ownershipClaims rootOwnershipClaims;
    };

  realizeChecks = {
    context,
    index,
    rootModules ? [],
    rootSource ? "<root checks>",
  }: let
    ownerModules = map (claim:
      claim
      // {
        module = args: callOwnerModule claim args;
      }) (contributionsFor index "checks");
    workspaceModules =
      lib.imap0 (position: module: {
        owner = "<root>";
        source =
          if builtins.isPath module
          then module
          else "${toString rootSource}#${toString position}";
        inherit module;
      })
      rootModules;
    contributions = workspaceModules ++ ownerModules;
    evaluate = specialArgs: modules:
      lib.evalModules {
        inherit specialArgs;
        modules = [./testing/check-options.nix] ++ modules;
      };
    evaluated = evaluate context (map (claim: claim.module) contributions);
    # Isolate definitions, not their module context: conditions and imported
    # function arguments must see the same fixed point as the combined result.
    # evalModules removes _module from config in its public result, but module
    # argument resolution still needs it for arguments supplied by other owners.
    claimContext =
      context
      // {
        config = evaluated.config // {inherit (evaluated) _module;};
        inherit (evaluated) options;
      };
    checkClaims = concatMap (claim: let
      isolated = evaluate claimContext [claim.module];
    in
      map (name: {
        keyPath = [name];
        inherit (claim) owner source;
        value = isolated.config.checks.${name};
      }) (attrNames isolated.config.checks))
    contributions;
    exclusive = mergeExclusiveClaims "checks" checkClaims;
    byName = listToAttrs (map (claim:
      nameValuePair (builtins.head claim.keyPath) claim)
    checkClaims);
  in {
    # Testing inputs stay lazy and independently accessible: the harness uses
    # them while the check modules construct their derivations.
    inherit (evaluated.config) testing;
    claims = deepSeq (attrNames exclusive) byName;
    checks = deepSeq (attrNames exclusive) evaluated.config.checks;
  };
}
