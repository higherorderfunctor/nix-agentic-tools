# config/generate-update-ninja.nix — generate .update.ninja from config.update.targets + flake.lock.
#
# Reads flake.lock for input follows relationships and config.update.targets
# for package update flags. Outputs a ninja build file with the full DAG.
#
# The flake passes `updateTargets = self.updateTargets`; the standalone doc
# path below self-evaluates the registry so it works without the flake:
#   nix eval --raw --impure --expr 'import ./config/generate-update-ninja.nix {}'
{
  flakeLock ? builtins.fromJSON (builtins.readFile ../flake.lock),
  updateTargets ? (
    let
      inherit (import <nixpkgs> {}) lib;
    in
      (lib.evalModules {
        modules = [
          ./../lib/update.nix
          ./update-targets.nix
          ./../overlays/mcp-servers/effect-mcp.update.nix
        ];
      })
      .config
      .update
      .targets
  ),
}: let
  inherit (flakeLock) nodes;
  rootInputs = nodes.root.inputs;
  inputNames = builtins.attrNames rootInputs;

  # Extract follows deps from flake.lock
  inputDeps =
    builtins.listToAttrs
    (map (
        name: let
          nodeName = rootInputs.${name};
          node = nodes.${nodeName};
          inputs = node.inputs or {};
        in {
          inherit name;
          value =
            if (inputs.nixpkgs or null) == ["nixpkgs"]
            then ["update-nixpkgs"]
            else [];
        }
      )
      inputNames);

  # Package dependencies beyond just nixpkgs. baseDeps is the universal rule
  # (every nix-update package depends on the nixpkgs + nix-update inputs);
  # per-package DAG predecessors (e.g. rust-overlay) come from the target's
  # own `dependsOn`, ordered AFTER baseDeps.
  pkgDeps = cfg: let
    baseDeps = ["update-nixpkgs" "update-nix-update"];
  in
    baseDeps ++ (map (d: "update-${d}") cfg.dependsOn);

  # treefmt-nix runs last — depends on ALL other targets
  allInputTargets = map (n: "update-${n}") (builtins.filter (n: n != "treefmt-nix") inputNames);
  allPkgTargets =
    builtins.attrValues
    (builtins.mapAttrs (name: _: "update-${name}") updateTargets);
  allNonTreefmtTargets = allInputTargets ++ allPkgTargets;

  # Ninja rules
  rules = ''
    # Rules
    rule pipeline-init
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && bash dev/scripts/update-init.sh 2>&1 | tee .update-logs/init.log'
      description = Pipeline init

    rule update-input
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && bash dev/scripts/update-input.sh $name 2>&1 | tee .update-logs/input-$name.log'
      description = Updating input: $name

    rule update-pkg
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && bash dev/scripts/update-pkg.sh $name $flags $git 2>&1 | tee .update-logs/pkg-$name.log'
      description = Updating package: $name

    rule full-format
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && { nix fmt && git add -A && git diff --staged --quiet || git commit -m "style: treefmt full reformat after updates"; } 2>&1 | tee .update-logs/full-format.log'
      description = Full treefmt (formatter config may have changed)

    rule final-build
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && source dev/scripts/update-common.sh && verify_all_packages 2>&1 | tee .update-logs/final-build.log'
      description = Final build verification (should be cached)

    rule report
      command = bash -c 'mkdir -p .update-logs && set -o pipefail && bash dev/scripts/update-report.sh 2>&1 | tee .update-logs/report.log'
      description = Update report
  '';

  # Init target — runs once before anything else
  initTarget = ''
    build update-init: pipeline-init
  '';

  # Input targets (all depend on init)
  inputTargets = builtins.concatStringsSep "\n" (map (name: let
    deps = inputDeps.${name} or [];
    allDeps = ["update-init"] ++ deps;
    depStr = " | ${builtins.concatStringsSep " " allDeps}";
  in ''
    build update-${name}: update-input${depStr}
      name = ${name}
  '') (builtins.filter (n: n != "treefmt-nix") inputNames));

  # Package targets
  pkgTargets = builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: cfg: let
      deps = pkgDeps cfg;
      depStr = " | ${builtins.concatStringsSep " " deps}";
      gitUrl =
        if cfg.git != null
        then cfg.git
        else "";
    in ''
      build update-${name}: update-pkg${depStr}
        name = ${name}
        flags = ${builtins.concatStringsSep " " cfg.flags}
        git = ${gitUrl}
    '')
    updateTargets));

  # treefmt last, then full format, then final build
  treefmtTarget = let
    allDeps = builtins.concatStringsSep " " allNonTreefmtTargets;
  in ''
    build update-treefmt-nix: update-input | ${allDeps}
      name = treefmt-nix

    build update-format: full-format | update-treefmt-nix

    build update-final-build: final-build | update-format
  '';

  # Meta targets
  metaTargets = let
    inputList = builtins.concatStringsSep " " allInputTargets;
    allList = builtins.concatStringsSep " " (allNonTreefmtTargets ++ ["update-treefmt-nix" "update-format" "update-final-build"]);
  in ''
    build update-inputs: phony | ${inputList}
    build update-all: phony | ${allList}
    build update-report: report | update-all

    # Finalize-only targets — run format + final-build + report
    # WITHOUT requiring the full package update chain. Use after
    # retrying a single failed package:
    #   ninja -f .update.ninja update-<pkg> update-finalize
    build update-format-only: full-format
    build update-final-build-only: final-build | update-format-only
    build update-report-only: report | update-final-build-only
    build update-finalize: phony | update-report-only

    default update-report
  '';

  ninja = builtins.concatStringsSep "\n" [
    "# Generated by config/generate-update-ninja.nix — do not edit."
    "# Regenerate: nix run .#generate-update-ninja"
    ""
    rules
    "# Pipeline init"
    initTarget
    ""
    "# Input updates"
    inputTargets
    ""
    "# Package updates"
    pkgTargets
    ""
    "# treefmt last (isolation)"
    treefmtTarget
    ""
    "# Meta targets"
    metaTargets
  ];
in
  ninja
