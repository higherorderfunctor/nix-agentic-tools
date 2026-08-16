{
  lib,
  pkgs,
  self,
}: let
  inherit (lib) all attrNames concatMapStringsSep escapeShellArgs hasPrefix sort;
  system = pkgs.stdenv.hostPlatform.system;
  fixtureRoot = ./fixtures/facets;
  compatibleRoot = fixtureRoot + "/compatible";
  collisionRoot = fixtureRoot + "/collisions";
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
  world = loader.compose {
    facetsDir = compatibleRoot;
    inherit pkgs specialArgs system;
    registryModules = [registryModule];
  };

  rootPolicy = import (fixtureRoot + "/root/overlay-policy.nix");
  composedOverlay = lib.composeExtensions world.overlay rootPolicy;
  overlayResult = lib.fix (
    final:
      {seed = "base";}
      // composedOverlay final {seed = "base";}
  );

  ownerNames = map (owner: owner.name) world.owners;
  localCheckValues = map (check: check.value) (builtins.attrValues world.localChecks);
  publicHomeManagerImports = self.homeManagerModules.default.imports or [];
  publicDevenvImports = self.devenvModules.nix-agentic-tools.imports or [];
  outsideFixture = module: !hasPrefix (toString fixtureRoot) (toString module);
  publicOverlayResult = self.overlays.default pkgs pkgs;

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
      == sort builtins.lessThan ownerNames
      && builtins.length ownerNames == 3;
    facet-lib-composition = world.facetLib.bravo.greeting == "hello-from-bravo";
    facet-local-checks =
      builtins.length localCheckValues
      == 5
      && all (value: value == true) localCheckValues;
    overlay-final-prev-and-root-policy =
      overlayResult.alpha-from-final
      == "alpha:alpha:bravo"
      && overlayResult.bravo-from-prev == "alpha:bravo"
      && overlayResult.facet-policy == "policy:alpha:alpha:bravo";
    public-output-invisibility =
      all (name: !(self.packages.${system} ? ${name})) (attrNames world.packages)
      && !(self.lib ? facets)
      && !(self.overlays ? facet-mock)
      && !(publicOverlayResult ? alpha-base)
      && !(publicOverlayResult ? alpha-from-final)
      && !(publicOverlayResult ? bravo-from-prev)
      && !(self.homeManagerModules ? facet-mock)
      && !(self.devenvModules ? facet-mock)
      && all outsideFixture publicHomeManagerImports
      && all outsideFixture publicDevenvImports;
    registry-composition =
      builtins.length (attrNames world.registry.facetMock.entries)
      == 3
      && world.registry.facetMock.entries.alpha.payload == "alpha"
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
        world = loader.compose {
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
        };
        overlayResult = lib.fix (final: world.overlay final {});
        localChecksPass = lib.all (check: check.value == true) (builtins.attrValues world.localChecks);
      in
        ${
        if probe.force == "checks"
        then "builtins.deepSeq world.localChecks true"
        else if probe.force == "false-check"
        then ''
          if localChecksPass
          then true
          else throw "facet local check failed: deliberate-false"
        ''
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
    scenario ? registry,
  }: let
    facetsDir = collisionRoot + "/${scenario}";
  in {
    inherit facetsDir force;
    name = registry;
    expected = [
      "facet collision in ${registry} at '${key}'"
      "one ("
      "/one/${
        if registry == "packages"
        then "packages/shared.nix"
        else "${registry}.nix"
      })"
      "two ("
      "/two/${
        if registry == "packages"
        then "packages/shared.nix"
        else "${registry}.nix"
      })"
    ];
  };

  probes = [
    (collisionProbe "checks" "shared" {})
    (collisionProbe "lib" "shared.value" {})
    (collisionProbe "overlay" "shared.value" {})
    (collisionProbe "packages" "shared" {})
    (collisionProbe "registry" "shared" {})
    {
      name = "false-check";
      facetsDir = collisionRoot + "/false-check";
      force = "false-check";
      expected = ["facet local check failed: deliberate-false"];
    }
    {
      name = "invalid-owner";
      facetsDir = collisionRoot + "/invalid-owner";
      force = "owners";
      expected = [
        "invalid owner 'Bad'"
        "/Bad"
        "allowed form: [a-z][a-z0-9-]*"
      ];
    }
    {
      name = "unknown-entry";
      facetsDir = collisionRoot + "/unknown-entry";
      force = "owners";
      expected = [
        "owner 'one'"
        "/one/unexpected.nix"
        "allowed forms:"
      ];
    }
    {
      name = "empty-owner";
      facetsDir = collisionRoot + "/empty-owner";
      force = "owners";
      expected = [
        "owner 'one'"
        "/one"
        "empty or documentation-only"
        "allowed forms require at least one facet contribution"
      ];
    }
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
