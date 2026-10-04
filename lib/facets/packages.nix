{
  lib,
  ensure,
  mergeExclusiveClaims,
}: let
  inherit (builtins) attrNames deepSeq readDir;
  inherit (lib) concatMap elem filter foldl' hasSuffix isDerivation;

  # Index paths before realizing any recipe. Namespace containers may be shared,
  # including empty ones; package leaves and their prefixes are exclusive.
  scan = owner: directory: prefix: let
    entries = readDir directory;
    source = directory + "/package.nix";
    platforms = directory + "/platforms.nix";
    leaf = keyPath: recipe: packageDirectory: platformFile: {
      inherit keyPath;
      inherit (owner) name;
      owner = owner.name;
      kind = "package";
      source = recipe;
      directory = packageDirectory;
      platforms = platformFile;
    };
  in
    if entries ? "package.nix"
    then
      deepSeq [
        (ensure (prefix != []) "owner '${owner.name}' packages root '${toString directory}' must be a namespace container")
        (ensure (entries."package.nix" == "regular") "owner '${owner.name}' package recipe '${toString source}' must be regular")
        (ensure (!(entries ? "platforms.nix") || entries."platforms.nix" == "regular") "owner '${owner.name}' package '${lib.showAttrPath prefix}' has non-regular platform metadata '${toString platforms}'")
      ] [
        (leaf prefix source directory (
          if entries ? "platforms.nix"
          then platforms
          else null
        ))
      ]
    else
      lib.optional (prefix != []) {
        inherit (owner) name;
        owner = owner.name;
        keyPath = prefix;
        kind = "namespace";
        source = directory;
      }
      ++ concatMap (
        name: let
          path = directory + "/${name}";
          type = entries.${name};
        in
          if type == "directory"
          then scan owner path (prefix ++ [name])
          else if type == "regular"
          then lib.optional (hasSuffix ".nix" name) (leaf (prefix ++ [(lib.removeSuffix ".nix" name)]) path null null)
          else throw "facet error: owner '${owner.name}' has unsupported package entry '${toString path}' (${type})"
      )
      (attrNames entries);

  # Package claims a system builds. Reads only platforms.nix files, so callers
  # without a package set (the exported overlay's claim list) can use it.
  eligibleFor = system: claim: claim.platforms == null || elem system (import claim.platforms);
  packageClaimsOf = index: filter (claim: claim.kind == "package") (concatMap (owner: owner.contributions.packages) index.owners);
  eligibleClaimsFor = {
    index,
    system,
  }:
    filter (eligibleFor system) (packageClaimsOf index);

  realize = {
    index,
    inputs,
    pkgs,
    scopeArgs ? {},
    system,
  }: let
    claims = concatMap (owner: owner.contributions.packages) index.owners;
    injectedArgs = scopeArgs // {inherit inputs pkgs system;};
    reservedNames = lib.unique (attrNames (lib.makeScope pkgs.newScope (_: {})) ++ attrNames injectedArgs ++ ["recurseForDerivations"]);
    reservedClaims = filter (claim: builtins.any (name: elem name reservedNames) claim.keyPath) claims;
    exclusive = mergeExclusiveClaims "packages" claims;
    packageClaims = packageClaimsOf index;
    eligibleClaims = filter (eligibleFor system) packageClaims;
    omittedClaims = filter (claim: !eligibleFor system claim) packageClaims;
    owners = filter (owner: owner.contributions.packages != []) index.owners;

    realizeOwner = owner: let
      original = owner.path + "/packages";
      omittedPaths = map (claim:
        toString (
          if claim.directory == null
          then claim.source
          else claim.directory
        )) (filter (claim: claim.owner == owner.name) omittedClaims);
      # Native discovery has no platform filter. Exclude unsupported leaves from
      # its input, so they are absent from native scopes as well as projections.
      # Recipes are still called at their ORIGINAL paths: relative source and
      # sidecar imports must retain their meaning, and copying must not alter drv
      # identity. No generated file or import-from-derivation is involved.
      directory =
        if omittedPaths == []
        then original
        else
          builtins.path {
            path = original;
            name = "facet-${owner.name}-packages";
            filter = path: _: !(elem path omittedPaths);
          };
      newScope = scope: recipe: args:
        (pkgs.newScope (injectedArgs // scope))
        (
          if (builtins.isPath recipe || builtins.isString recipe) && lib.hasPrefix "${toString directory}/" (toString recipe)
          then original + builtins.unsafeDiscardStringContext (lib.removePrefix (toString directory) (toString recipe))
          else recipe
        )
        args;
    in
      lib.filesystem.packagesFromDirectoryRecursive {
        inherit directory newScope;
        callPackage = newScope {};
      };
    scopes = lib.genAttrs (map (owner: owner.name) owners) (
      name: realizeOwner (builtins.head (filter (owner: owner.name == name) owners))
    );
    packages =
      foldl' (
        tree: claim:
          lib.recursiveUpdate tree (lib.setAttrByPath claim.keyPath (
            let
              value = lib.getAttrFromPath claim.keyPath scopes.${claim.owner};
            in
              assert ensure (isDerivation value) "owner '${claim.owner}' package '${lib.showAttrPath claim.keyPath}' at '${toString claim.source}' returned a non-derivation"; value
          ))
      ) {}
      eligibleClaims;
    reserved = builtins.head reservedClaims;
    reservedName = builtins.head (filter (name: elem name reservedNames) reserved.keyPath);
    validations = [
      (ensure (reservedClaims == []) "reserved package name '${reservedName}' from owner '${reserved.owner}' at '${toString reserved.source}' would overwrite a native or injected scope member")
    ];
  in
    deepSeq [exclusive validations] {
      inherit claims eligibleClaims packages scopes;
      omitted = map (claim: claim.keyPath) omittedClaims;
    };
in {
  inherit eligibleClaimsFor realize scan;
}
