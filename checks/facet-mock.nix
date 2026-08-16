{
  lib,
  pkgs,
  self,
}: let
  inherit
    (lib)
    all
    attrNames
    concatMap
    concatMapStringsSep
    escapeShellArgs
    filter
    genAttrs
    hasPrefix
    listToAttrs
    mapAttrs
    nameValuePair
    optionalAttrs
    sort
    ;
  system = pkgs.stdenv.hostPlatform.system;
  fixtureRoot = ./fixtures/facets;
  compatibleRoot = fixtureRoot + "/compatible";
  collisionRoot = fixtureRoot + "/collisions";
  enforceLocalChecks = import (fixtureRoot + "/root/enforce-local-checks.nix") {inherit lib;};
  registryModule = fixtureRoot + "/root/registry.nix";
  loader = import ../lib/facets.nix {inherit lib;};

  specialArgs = {
    common = {
      fixtureToken = "common";
      inherit pkgs system;
    };
    devenv = {devenvOnly = "devenv";};
    homeManager = {hmOnly = "home-manager";};
  };
  coreWorld = loader.compose {
    facetsDir = compatibleRoot;
    inherit pkgs specialArgs system;
    registryModules = [registryModule];
  };
  world = enforceLocalChecks coreWorld;

  compatibleEntries = builtins.readDir compatibleRoot;
  expectedOwnerNames = sort builtins.lessThan (filter (name: compatibleEntries.${name} == "directory") (attrNames compatibleEntries));
  expectedContributions = ownerName: let
    ownerRoot = compatibleRoot + "/${ownerName}";
    entries = builtins.readDir ownerRoot;
    present = name: entries ? ${name};
    modulesPath = ownerRoot + "/modules";
    packagesPath = ownerRoot + "/packages";
    moduleNames =
      if present "modules"
      then attrNames (builtins.readDir modulesPath)
      else [];
    packageNames =
      if present "packages"
      then attrNames (builtins.readDir packagesPath)
      else [];
  in
    optionalAttrs (present "checks.nix") {checks = toString (ownerRoot + "/checks.nix");}
    // optionalAttrs (present "lib.nix") {lib = toString (ownerRoot + "/lib.nix");}
    // optionalAttrs (moduleNames != []) {
      modules = genAttrs moduleNames (name: toString (modulesPath + "/${name}"));
    }
    // optionalAttrs (present "overlay.nix") {overlay = toString (ownerRoot + "/overlay.nix");}
    // optionalAttrs (packageNames != []) {
      packages = map (name: toString (packagesPath + "/${name}")) packageNames;
    }
    // optionalAttrs (present "registry.nix") {registry = toString (ownerRoot + "/registry.nix");};
  normalizeContributions = contributions:
    mapAttrs (
      name: value:
        if name == "modules"
        then mapAttrs (_: toString) value
        else if name == "packages"
        then map toString value
        else toString value
    )
    contributions;
  expectedLocalCheckClaims =
    concatMap (
      owner: let
        source = compatibleRoot + "/${owner}/checks.nix";
      in
        if builtins.pathExists source
        then let
          imported = import source;
          checks =
            if builtins.isFunction imported
            then
              imported {
                inherit lib pkgs system;
                world = coreWorld;
              }
            else imported;
        in
          map (key: {
            inherit key owner source;
          }) (attrNames checks)
        else []
    )
    expectedOwnerNames;
  expectedLocalCheckProvenance = listToAttrs (map (
      claim:
        nameValuePair claim.key {
          inherit (claim) owner;
          source = toString claim.source;
        }
    )
    expectedLocalCheckClaims);
  actualLocalCheckProvenance =
    mapAttrs (_: check: {
      inherit (check) owner;
      source = toString check.source;
    })
    world.localChecks;

  rootPolicy = import (fixtureRoot + "/root/overlay-policy.nix");
  composedOverlay = lib.composeExtensions world.overlay rootPolicy;
  overlayResult = lib.fix (
    final:
      {seed = "base";}
      // composedOverlay final {seed = "base";}
  );

  ownerNames = map (owner: owner.name) world.owners;
  publicHomeManagerImports = self.homeManagerModules.default.imports or [];
  publicDevenvImports = self.devenvModules.nix-agentic-tools.imports or [];
  outsideFixture = module: !hasPrefix (toString fixtureRoot) (toString module);
  publicOverlayResult = self.overlays.default pkgs pkgs;
  publicAiLib = self.lib.ai or {};
  mockOverlayNames = filter (name: name != "seed") (attrNames overlayResult);

  assertions = {
    backend-isolation =
      world.homeManager.config.facetMock.homeManager
      == {
        observed = "common:home-manager";
        sawDevenvOnly = false;
      }
      && world.devenv.config.facetMock.devenv
      == {
        observed = "common:devenv";
        sawHmOnly = false;
      }
      && !(world.homeManager.options.facetMock ? devenv)
      && !(world.devenv.options.facetMock ? homeManager);
    call-package-cross-facet =
      lib.isDerivation world.packages.alpha-app
      && lib.isDerivation world.packages.bravo-tool
      && world.packages.alpha-app.bravoDrvPath == world.packages.bravo-tool.drvPath
      && world.packages.alpha-app.decorated == "hello-from-bravo:alpha";
    deterministic-discovery =
      ownerNames
      == expectedOwnerNames
      && all (
        owner:
          toString owner.path
          == toString (compatibleRoot + "/${owner.name}")
          && normalizeContributions owner.contributions
          == expectedContributions owner.name
      )
      world.owners;
    facet-lib-composition = world.facetLib.bravo.greeting == "hello-from-bravo";
    facet-local-checks =
      actualLocalCheckProvenance
      == expectedLocalCheckProvenance;
    overlay-final-prev-and-root-policy =
      overlayResult.alpha-from-final
      == "alpha:alpha:bravo"
      && overlayResult.bravo-from-prev == "alpha:bravo"
      && overlayResult.facet-policy == "policy:alpha:alpha:bravo";
    public-output-invisibility =
      all (name: !(self.packages.${system} ? ${name})) (attrNames world.packages)
      && !(self.lib ? facets)
      && !(publicAiLib ? facets)
      && !(self.overlays ? facet-mock)
      && all (name: !(publicOverlayResult ? ${name})) mockOverlayNames
      && !(self.homeManagerModules ? facet-mock)
      && !(self.devenvModules ? facet-mock)
      && all outsideFixture publicHomeManagerImports
      && all outsideFixture publicDevenvImports;
    registry-composition =
      world.registry.facetMock.entries.alpha.payload
      == "alpha:common:module"
      && world.registry.facetMock.entries.bravo.payload == "bravo";
  };
  assertionsPass = all (value: value == true) (builtins.attrValues assertions);

  positiveCheck = assert assertionsPass;
    pkgs.runCommandLocal "facet-mock" {
      nativeBuildInputs = [world.packages.alpha-app];
    } ''
      test -e ${world.packages.alpha-app}/marker
      mkdir -p "$out"
      touch "$out/passed"
    '';

  mkProbeExpression = probe:
    pkgs.writeText "facet-mock-${probe.name}-probe.nix" ''
      {facetsDir ? ${probe.facetsDir}}: let
        pkgs = import ${pkgs.path} {system = ${builtins.toJSON system};};
        lib = pkgs.lib;
        loader = import ${../lib/facets.nix} {inherit lib;};
        enforceLocalChecks = import ${fixtureRoot + "/root/enforce-local-checks.nix"} {inherit lib;};
        world = enforceLocalChecks (
          loader.compose {
            inherit facetsDir pkgs;
            system = ${builtins.toJSON system};
            registryModules = [${registryModule}];
            specialArgs = {
              common = {
                fixtureToken = "common";
                system = ${builtins.toJSON system};
              };
              devenv.devenvOnly = "devenv";
              homeManager.hmOnly = "home-manager";
            };
          }
        );
        overlayResult = lib.fix (final: world.overlay final {});
      in
        ${
        if probe.force == "checks"
        then "builtins.deepSeq world.localChecks true"
        else if probe.force == "lib"
        then "builtins.deepSeq world.facetLib true"
        else if probe.force == "overlay"
        then "builtins.deepSeq overlayResult true"
        else if probe.force == "owners"
        then "builtins.deepSeq world.owners true"
        else if probe.force == "packages"
        then "builtins.deepSeq world.packages true"
        else if probe.force == "registry"
        then "builtins.deepSeq world.registry.facetMock.entries true"
        else throw "unknown facet mock probe force '${probe.force}'"
      }
    '';

  collisionProbe = registry: key: {
    force ? registry,
    name ? registry,
    scenario ? registry,
  }: let
    facetsDir = collisionRoot + "/${scenario}";
    sourceFile =
      if registry == "packages"
      then "packages/shared.nix"
      else "${registry}.nix";
  in {
    inherit facetsDir force name;
    expected = [
      "facet collision in ${registry} at '${key}'"
      "owner-source:one:one/${sourceFile}"
      "owner-source:two:two/${sourceFile}"
    ];
  };

  scannerProbe = scenario: expected: {
    facetsDir = collisionRoot + "/${scenario}";
    force = "owners";
    name = scenario;
    inherit expected;
  };

  probes = [
    (collisionProbe "checks" "shared" {})
    (collisionProbe "lib" "shared.__facetLeaf" {})
    (collisionProbe "lib" "shared" {
      name = "lib-empty-branch-first";
      scenario = "lib-empty-branch-first";
    })
    (collisionProbe "lib" "shared" {
      name = "lib-empty-leaf-first";
      scenario = "lib-empty-leaf-first";
    })
    (collisionProbe "overlay" "shared.value" {})
    (collisionProbe "packages" "shared" {})
    (collisionProbe "registry" "shared" {})
    {
      name = "false-check";
      facetsDir = collisionRoot + "/false-check";
      force = "checks";
      expected = ["facet local check failed: deliberate-false"];
    }
    (scannerProbe "invalid-owner" [
      "invalid owner 'Bad'"
      "/Bad"
      "allowed form: [a-z][a-z0-9-]*"
    ])
    (scannerProbe "unknown-entry" [
      "owner 'one'"
      "/one/unexpected.nix"
      "allowed forms:"
    ])
    (scannerProbe "empty-owner" [
      "owner 'one'"
      "/one"
      "empty or documentation-only"
      "allowed forms require at least one facet contribution"
    ])
    (scannerProbe "root-non-directory" [
      "facets directory"
      "root-non-directory/one"
      "contains non-directory owner entry"
      "allowed forms: immediate owner directories"
    ])
    (scannerProbe "packages-non-directory" [
      "owner 'one'"
      "/one/packages"
      "non-directory contribution container"
      "allowed forms require directories"
    ])
    (scannerProbe "modules-non-directory" [
      "owner 'one'"
      "/one/modules"
      "non-directory contribution container"
      "allowed forms require directories"
    ])
    (scannerProbe "package-invalid-entry" [
      "owner 'one'"
      "/one/packages/Bad.txt"
      "invalid package entry"
      "allowed forms: regular <export>.nix files with lowercase kebab-case names"
    ])
    (scannerProbe "package-non-regular" [
      "owner 'one'"
      "/one/packages/shared.nix"
      "invalid package entry"
      "allowed forms: regular <export>.nix files with lowercase kebab-case names"
    ])
    (scannerProbe "module-unknown" [
      "owner 'one'"
      "/one/modules/other.nix"
      "unknown module"
      "allowed forms: devenv.nix, homeManager.nix"
    ])
    (scannerProbe "module-non-regular" [
      "owner 'one'"
      "/one/modules/devenv.nix"
      "non-regular module"
      "allowed forms require regular Nix files"
    ])
  ];

  probeCommands =
    concatMapStringsSep "\n" (
      probe: "run_probe ${escapeShellArgs ([probe.name (toString (mkProbeExpression probe)) "${probe.facetsDir}"] ++ probe.expected)}"
    )
    probes;
  symlinkProbe = mkProbeExpression {
    name = "symlink";
    facetsDir = compatibleRoot;
    force = "owners";
  };

  negativeCheck =
    pkgs.runCommandLocal "facet-mock-negative" {
      nativeBuildInputs = [pkgs.nix];
    } ''
      export HOME="$PWD/home"
      export NIX_STATE_DIR="$PWD/nix-state"
      mkdir -p "$HOME" "$NIX_STATE_DIR/profiles/per-user/$USER"

      run_probe() {
        local name="$1"
        local expression="$2"
        local facets_dir="$3"
        shift 3

        if ${pkgs.nix}/bin/nix-instantiate --eval --strict "$expression" --argstr facetsDir "$facets_dir" \
          >"$name.stdout" 2>"$name.stderr"; then
          echo "facet mock negative probe unexpectedly succeeded: $name" >&2
          return 1
        fi

        local expected
        for expected in "$@"; do
          case "$expected" in
            owner-source:*)
              local pair="''${expected#owner-source:}"
              local pair_owner="''${pair%%:*}"
              local pair_path="''${pair#*:}"
              expected="$pair_owner ($facets_dir/$pair_path)"
              ;;
            *) ;;
          esac
          if ! ${pkgs.gnugrep}/bin/grep -F -- "$expected" "$name.stderr" >/dev/null; then
            echo "facet mock negative probe missed diagnostic '$expected': $name" >&2
            ${pkgs.coreutils}/bin/cat "$name.stderr" >&2
            return 1
          fi
        done
      }

      ${probeCommands}

      mkdir -p symlink-fixture/one
      ln -s ${compatibleRoot}/bravo/lib.nix symlink-fixture/one/lib.nix
      if ${pkgs.nix}/bin/nix-instantiate --eval --strict "${symlinkProbe}" \
        --argstr facetsDir "$PWD/symlink-fixture" \
        >symlink.stdout 2>symlink.stderr; then
        echo "facet mock symlink probe unexpectedly succeeded" >&2
        false
      fi
      ${pkgs.gnugrep}/bin/grep -F -- "owner 'one'" symlink.stderr >/dev/null
      ${pkgs.gnugrep}/bin/grep -F -- "$PWD/symlink-fixture/one/lib.nix" symlink.stderr >/dev/null
      ${pkgs.gnugrep}/bin/grep -F -- "allowed forms require regular Nix/README files" symlink.stderr >/dev/null

      mkdir -p "$out"
      touch "$out/passed"
    '';
in {
  facet-mock = positiveCheck;
  facet-mock-negative = negativeCheck;
}
