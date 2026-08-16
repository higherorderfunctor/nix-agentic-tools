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
      devenvConfig = devenvEvaluation.config;
      homeManagerConfig = homeManagerEvaluation.config;
      index = facetIndex;
      inherit (packageWorld) packages;
      omittedPackages = packageWorld.omitted;
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
  outsideFixture = module: !hasPrefix "${toString fixtureRoot}/" (toString module);
  publicOverlayResult = self.overlays.default pkgs pkgs;
  publicAiLib = self.lib.ai or {};
  gitRevise = packageWorld.packages.git-revise;
  sameValue = left: right: let
    compared = builtins.tryEval (
      if lib.isDerivation left && lib.isDerivation right
      then left.drvPath == right.drvPath
      else left == right
    );
  in
    compared.success && compared.value;
  fixturePackageValues = filter lib.isDerivation (builtins.attrValues packageWorld.packages);
  publicPackageValues = filter lib.isDerivation (builtins.attrValues self.packages.${system});
  fixtureOverlayValues =
    map (claim: {
      inherit (claim) keyPath;
      value = lib.attrByPath claim.keyPath null overlayResult;
    })
    overlayWorld.ownershipClaims;

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
    overlay-order-and-namespace =
      overlayResult.ai.seed
      == inputs.fixture.sentinel
      && overlayResult.ai.alpha == "${inputs.fixture.sentinel}:alpha"
      && overlayResult.ai.gitReviseObserved
      == "${inputs.fixture.sentinel}:${inputs.fixture.sentinel}:alpha"
      && overlayResult.ai.gitTools.git-revise.drvPath == gitRevise.drvPath;
    package-identity =
      packageWorld.scope.git-revise.drvPath
      == gitRevise.drvPath
      && overlayResult.ai.gitTools.git-revise.drvPath == gitRevise.drvPath;
    public-output-invisibility =
      all (
        fixturePackage:
          all (publicPackage: publicPackage.drvPath != fixturePackage.drvPath) publicPackageValues
      )
      fixturePackageValues
      && !(self.lib ? facets)
      && !(publicAiLib ? facets)
      && !(self.overlays ? facet-mock)
      && all (
        fixtureLeaf:
          !sameValue
          fixtureLeaf.value
          (lib.attrByPath fixtureLeaf.keyPath null publicOverlayResult)
      )
      fixtureOverlayValues
      && !(self.homeManagerModules ? facet-mock)
      && !(self.devenvModules ? facet-mock)
      && all outsideFixture publicHomeManagerImports
      && all outsideFixture publicDevenvImports;
    registry-native-realization =
      attrNames registryWorld.config.facetMock.entries
      == registryClaimKeys;
  };
  assertionsPass = all (value: value == true) (builtins.attrValues assertions);

  positiveCheck = assert assertionsPass;
    pkgs.runCommandLocal "facet-mock" {
      nativeBuildInputs = localCheckValues ++ [gitRevise];
      passthru.localChecks = localChecks;
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
        then ''
          let
            world = loader.realizeOverlay { inherit context index; };
            base.ai.seed = inputs.fixture.sentinel;
            result = lib.fix (final: base // world.overlay final base);
          in builtins.deepSeq result true
        ''
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
      name = "check-collision";
      force = "checks";
      expected = [
        "facet ownership collision in checks at 'shared'"
        "/one/checks.nix"
        "/two/checks.nix"
      ];
    })
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
      name = "invalid-owner";
      force = "index";
      expected = [
        "invalid owner 'Bad'"
        "expected lowercase kebab-case"
      ];
    })
    (probe {
      name = "metadata-only";
      force = "index";
      expected = [
        "owner 'one'"
        "is metadata-only"
      ];
    })
    (probe {
      name = "metadata-unsupported";
      force = "index";
      expected = [
        "owner 'one' has unclassified metadata"
        "/one/unclassified.txt"
      ];
    })
    (probe {
      name = "module-missing-default";
      force = "index";
      expected = [
        "/one/modules/devenv"
        "must be a directory with regular default.nix"
      ];
    })
    (probe {
      name = "module-non-directory";
      force = "index";
      expected = [
        "/one/modules/devenv"
        "must be a directory with regular default.nix"
      ];
    })
    (probe {
      name = "module-unknown";
      force = "index";
      expected = [
        "has unknown module entry"
        "/one/modules/other"
      ];
    })
    (probe {
      name = "modules-non-directory";
      force = "index";
      expected = [
        "has non-directory contribution container"
        "/one/modules"
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
      name = "overlay-malformed-claim";
      force = "overlay";
      expected = [
        "owner 'one' overlay claims"
        "must contain non-empty lists of non-empty strings"
      ];
    })
    (probe {
      name = "overlay-prefix";
      force = "overlay";
      expected = [
        "facet ownership collision in overlay"
        "/one/overlay.nix"
        "/two/overlay.nix"
      ];
    })
    (probe {
      name = "overlay-undeclared";
      force = "overlay";
      expected = [
        "owner 'one' overlay"
        "writes undeclared leaf 'ai.shared'"
      ];
    })
    (probe {
      name = "overlay-unwritten";
      force = "overlay";
      expected = [
        "owner 'one' overlay"
        "claims unwritten leaf 'ai.shared'"
      ];
    })
    (probe {
      name = "package-invalid-name";
      force = "index";
      expected = [
        "invalid package name 'Bad'"
        "expected lowercase kebab-case"
      ];
    })
    (probe {
      name = "package-missing-recipe";
      force = "index";
      expected = [
        "package 'shared' is missing regular recipe"
        "/one/packages/shared/package.nix"
      ];
    })
    (probe {
      name = "package-non-directory";
      force = "index";
      expected = [
        "package 'shared'"
        "must be a directory"
      ];
    })
    (probe {
      name = "package-platforms-non-regular";
      force = "index";
      expected = [
        "package 'shared' has non-regular platform metadata"
        "/one/packages/shared/platforms.nix"
      ];
    })
    (probe {
      name = "packages-non-directory";
      force = "index";
      expected = [
        "has non-directory contribution container"
        "/one/packages"
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
    (probe {
      name = "root-non-directory";
      force = "index";
      expected = [
        "contains non-directory owner"
        "/one"
      ];
    })
  ];
  successProbes = [
    (probe {
      name = "overlay-dotted-alias";
      force = "overlay";
      expected = [];
    })
  ];
  probeCommands =
    concatMapStringsSep "\n" (
      item: "run_probe ${escapeShellArgs ([item.name (toString (mkProbeExpression item)) "${item.facetsDir}"] ++ item.expected)}"
    )
    probes;
  successProbeCommands =
    concatMapStringsSep "\n" (
      item: "run_success_probe ${escapeShellArgs [item.name (toString (mkProbeExpression item)) "${item.facetsDir}"]}"
    )
    successProbes;

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

      run_success_probe() {
        local name="$1"
        local expression="$2"
        local facets_dir="$3"

        if ! ${pkgs.nix}/bin/nix-instantiate --eval --strict "$expression" --argstr facetsDir "$facets_dir" \
          >"$name.stdout" 2>"$name.stderr"; then
          echo "facet mock positive probe unexpectedly failed: $name" >&2
          ${pkgs.coreutils}/bin/cat "$name.stderr" >&2
          return 1
        fi
      }

      ${probeCommands}
      ${successProbeCommands}

      mkdir -p symlink-fixture/one
      ln -s ${productionRoot}/alpha/checks.nix symlink-fixture/one/checks.nix
      run_probe \
        symlink-contribution \
        ${lib.escapeShellArg (toString (mkProbeExpression {
        name = "symlink-contribution";
        facetsDir = productionRoot;
        force = "index";
      }))} \
        "$PWD/symlink-fixture" \
        "owner 'one' has non-regular contribution" \
        "/one/checks.nix"

      mkdir -p "$out"
      touch "$out/passed"
    '';
in {
  facet-mock = positiveCheck;
  facet-mock-negative = negativeCheck;
}
