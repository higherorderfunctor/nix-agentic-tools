{
  lib,
  pkgs,
  self,
}: let
  inherit
    (lib)
    all
    attrNames
    concatMapStringsSep
    escapeShellArgs
    filter
    hasPrefix
    mapAttrs
    sort
    ;

  system = pkgs.stdenv.hostPlatform.system;
  fixtureRoot = ./fixtures/facets;
  productionRoot = fixtureRoot + "/production";
  negativeRoot = fixtureRoot + "/negative";
  registryModule = fixtureRoot + "/root/registry.nix";
  loader = import ../lib/facets.nix {inherit lib;};
  inputs.fixture.sentinel = "facet-input-sentinel";

  facetIndex = loader.index {facetsDir = productionRoot;};
  packageWorld = loader.realizePackages {
    inherit inputs pkgs system;
    index = facetIndex;
  };
  homeManagerModules = loader.moduleImports {
    backend = "homeManager";
    index = facetIndex;
  };
  devenvModules = loader.moduleImports {
    backend = "devenv";
    index = facetIndex;
  };
  homeManagerEvaluation = lib.evalModules {modules = homeManagerModules;};
  devenvEvaluation = lib.evalModules {modules = devenvModules;};
  registryWorld = loader.realizeRegistry {
    claimPath = ["facetMock" "entries"];
    index = facetIndex;
    modules = [registryModule];
    specialArgs = {inherit inputs;};
  };
  overlayWorld = loader.realizeOverlay {
    context = {
      inherit inputs;
      inherit (packageWorld) packages;
    };
    index = facetIndex;
  };
  overlayBase.ai.seed = inputs.fixture.sentinel;
  overlayResult = lib.fix (
    final:
      overlayBase
      // overlayWorld.overlay final overlayBase
  );

  localChecks = loader.realizeChecks {
    context = {
      inherit
        devenvModules
        facetIndex
        homeManagerModules
        inputs
        lib
        overlayResult
        pkgs
        self
        system
        ;
      index = facetIndex;
      inherit (packageWorld) packages;
      registry = registryWorld.config;
    };
    index = facetIndex;
  };
  localCheckNames = attrNames localChecks;
  localCheckValues = map (name: localChecks.${name}.value) localCheckNames;
  localCheckBuildCommands =
    concatMapStringsSep "\n" (
      name: "test -e ${localChecks.${name}.value}/passed"
    )
    localCheckNames;

  ownerNames = map (owner: owner.name) facetIndex.owners;
  publicHomeManagerImports = self.homeManagerModules.default.imports or [];
  publicDevenvImports = self.devenvModules.nix-agentic-tools.imports or [];
  outsideFixture = module: !hasPrefix (toString fixtureRoot) (toString module);
  publicOverlayResult = self.overlays.default pkgs pkgs;
  publicAiLib = self.lib.ai or {};
  gitRevise = packageWorld.packages.git-revise;

  registryClaimKeys = sort builtins.lessThan (
    map (claim: builtins.elemAt claim.keyPath 2) registryWorld.ownershipClaims
  );
  assertions = {
    deterministic-index =
      ownerNames
      == sort builtins.lessThan ownerNames
      && all (
        owner:
          toString owner.path
          == toString (productionRoot + "/${owner.name}")
          && all (
            contribution:
              contribution.owner
              == owner.name
              && hasPrefix (toString owner.path) (toString contribution.source)
          ) (
            owner.contributions.packages
            ++ builtins.attrValues owner.contributions.modules
            ++ filter (value: value != null) [
              owner.contributions.checks
              owner.contributions.overlay
              owner.contributions.registry
            ]
          )
      )
      facetIndex.owners;
    module-consumer-shape =
      homeManagerEvaluation.config.facetMock.shared
      == {
        backend = "home-manager";
        enabled = true;
        label = "git-revise";
      }
      && devenvEvaluation.config.facetMock.shared
      == {
        backend = "devenv";
        enabled = true;
        label = "git-revise";
      };
    overlay-order-and-namespace =
      overlayResult.ai.seed
      == inputs.fixture.sentinel
      && overlayResult.ai.alpha == "${inputs.fixture.sentinel}:alpha"
      && overlayResult.ai.gitReviseObserved
      == "${inputs.fixture.sentinel}:${inputs.fixture.sentinel}:alpha"
      && overlayResult.ai.gitTools.git-revise.drvPath == gitRevise.drvPath;
    package-identity-and-platform-omission =
      packageWorld.scope.git-revise.drvPath
      == gitRevise.drvPath
      && overlayResult.ai.gitTools.git-revise.drvPath == gitRevise.drvPath
      && (
        if system == "aarch64-darwin"
        then packageWorld.packages ? unsupported-control
        else
          !(packageWorld.packages ? unsupported-control)
          && builtins.elem "unsupported-control" packageWorld.omitted
      );
    public-output-invisibility =
      all (
        package:
          !lib.isDerivation package
          || package.drvPath != gitRevise.drvPath
      ) (builtins.attrValues self.packages.${system})
      && !(self.lib ? facets)
      && !(publicAiLib ? facets)
      && !(self.overlays ? facet-mock)
      && publicOverlayResult.ai.gitTools.git-revise.drvPath != gitRevise.drvPath
      && !(self.homeManagerModules ? facet-mock)
      && !(self.devenvModules ? facet-mock)
      && all outsideFixture publicHomeManagerImports
      && all outsideFixture publicDevenvImports;
    registry-native-realization =
      attrNames registryWorld.config.facetMock.entries
      == registryClaimKeys
      && registryWorld.config.facetMock.entries.alpha.payload == "alpha"
      && registryWorld.config.facetMock.entries.git-revise.payload
      == inputs.fixture.sentinel;
  };
  assertionsPass = all (value: value == true) (builtins.attrValues assertions);

  positiveCheck = assert assertionsPass;
    pkgs.runCommandLocal "facet-mock" {
      nativeBuildInputs = localCheckValues ++ [gitRevise];
      passthru.localChecks = mapAttrs (_: claim: claim.value) localChecks;
    } ''
      ${localCheckBuildCommands}
      test "$(cat ${gitRevise}/marker)" = ${lib.escapeShellArg inputs.fixture.sentinel}
      mkdir -p "$out"
      touch "$out/passed"
    '';

  mkProbeExpression = probe:
    pkgs.writeText "facet-mock-${probe.name}-probe.nix" ''
      {facetsDir ? ${probe.facetsDir}}: let
        pkgs = import ${pkgs.path} {system = ${builtins.toJSON system};};
        lib = pkgs.lib;
        loader = import ${../lib/facets.nix} {inherit lib;};
        index = loader.index {inherit facetsDir;};
        inputs.fixture.sentinel = "facet-input-sentinel";
        context = {
          inherit inputs lib pkgs;
          self = {};
          system = ${builtins.toJSON system};
        };
      in
        ${
        if probe.force == "checks"
        then "builtins.deepSeq (loader.realizeChecks { inherit context index; }) true"
        else if probe.force == "index"
        then "builtins.deepSeq index true"
        else if probe.force == "overlay"
        then "builtins.deepSeq (loader.realizeOverlay { inherit context index; }) true"
        else if probe.force == "packages"
        then ''
          builtins.deepSeq (loader.realizePackages {
            inherit index inputs pkgs;
            system = ${builtins.toJSON system};
          }) true
        ''
        else if probe.force == "registry"
        then ''
          builtins.deepSeq (loader.realizeRegistry {
            claimPath = ["facetMock" "entries"];
            inherit index;
            modules = [${registryModule}];
          }) true
        ''
        else throw "unknown facet mock probe force '${probe.force}'"
      }
    '';

  probe = {
    expected,
    force,
    name,
    scenario ? name,
  }: {
    facetsDir = negativeRoot + "/${scenario}";
    inherit expected force name;
  };
  probes = [
    (probe {
      name = "check-non-derivation";
      force = "checks";
      expected = [
        "owner 'one' check 'invalid'"
        "/one/checks.nix"
        "returned a non-derivation"
      ];
    })
    (probe {
      name = "overlay-collision";
      force = "overlay";
      expected = [
        "facet ownership collision in overlay at 'ai.shared'"
        "one ("
        "/one/overlay.nix"
        "two ("
        "/two/overlay.nix"
      ];
    })
    (probe {
      name = "package-collision";
      force = "packages";
      expected = [
        "facet ownership collision in packages at 'shared'"
        "/one/packages/shared/package.nix"
        "/two/packages/shared/package.nix"
      ];
    })
    (probe {
      name = "registry-equal";
      force = "registry";
      expected = [
        "facet ownership collision in registry at 'facetMock.entries.shared'"
        "/one/registry.nix"
        "/two/registry.nix"
      ];
    })
    (probe {
      name = "registry-mixed";
      force = "registry";
      expected = [
        "facet ownership collision in registry at 'facetMock.entries.shared'"
        "/one/registry.nix"
        "/two/registry.nix"
      ];
    })
    (probe {
      name = "reserved-packages";
      force = "packages";
      expected = [
        "reserved package name 'packages'"
        "owner 'one'"
        "/one/packages/packages/package.nix"
      ];
    })
    (probe {
      name = "reserved-pkgs";
      force = "packages";
      expected = [
        "reserved package name 'pkgs'"
        "owner 'one'"
        "/one/packages/pkgs/package.nix"
      ];
    })
    (probe {
      name = "reserved-system";
      force = "packages";
      expected = [
        "reserved package name 'system'"
        "owner 'one'"
        "/one/packages/system/package.nix"
      ];
    })
  ];
  probeCommands =
    concatMapStringsSep "\n" (
      item: "run_probe ${escapeShellArgs ([item.name (toString (mkProbeExpression item)) "${item.facetsDir}"] ++ item.expected)}"
    )
    probes;

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

      mkdir -p "$out"
      touch "$out/passed"
    '';
in {
  facet-mock = positiveCheck;
  facet-mock-negative = negativeCheck;
}
