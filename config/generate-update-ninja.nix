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

  # Every package starts after pipeline initialization, followed by any
  # explicitly declared target-specific ordering constraints (e.g.
  # rust-overlay). Input targets
  # update isolated branches, so separate nixpkgs and nix-update branches
  # cannot feed state into package worktrees and must not serialize the whole
  # package fanout.
  pkgDeps = cfg: ["update-init"] ++ (map (d: "update-${d}") cfg.dependsOn);

  # treefmt-nix runs last — depends on ALL other targets
  allInputTargets = map (n: "update-${n}") (builtins.filter (n: n != "treefmt-nix") inputNames);
  allPkgTargets =
    builtins.attrValues
    (builtins.mapAttrs (name: _: "update-${name}") updateTargets);
  allNonTreefmtTargets = allInputTargets ++ allPkgTargets;

  # Full strict mode for every generated rule body. The repo standard
  # applies to generated wrappers too, not just files on disk, and these
  # `bash -c` bodies are exactly that.
  #
  # SEPARATORS ARE `;`, NEVER `&&`. `shopt ... || :` has to bind to the
  # shopt alone; in an `&&` chain the trailing `|| :` binds to the WHOLE
  # chain, so `false && set -e && shopt ... || :` exits 0 and silently
  # swallows the earlier failure. Verified both ways before landing this.
  #
  # `pipefail` is the load-bearing member for these particular bodies:
  # every one of them ends in `| tee`, and without it tee's exit status
  # would mask a failing target.
  strictPrelude = "set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :; mkdir -p .update-logs;";

  # Ninja rules
  rules = ''
    # Rules
    rule pipeline-init
      command = bash -c '${strictPrelude} bash dev/scripts/update-init.sh 2>&1 | tee .update-logs/init.log'
      description = Pipeline init

    rule update-input
      command = bash -c '${strictPrelude} bash dev/scripts/update-input.sh $name 2>&1 | tee .update-logs/input-$name.log'
      description = Updating input: $name

    rule update-pkg
      command = bash -c '${strictPrelude} bash dev/scripts/update-pkg.sh $name $flags $git 2>&1 | tee .update-logs/pkg-$name.log'
      description = Updating package: $name

    rule report
      command = bash -c '${strictPrelude} bash dev/scripts/update-report.sh 2>&1 | tee .update-logs/report.log'
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

  # treefmt-nix updates last, after every other isolated target
  treefmtTarget = let
    allDeps = builtins.concatStringsSep " " allNonTreefmtTargets;
  in ''
    build update-treefmt-nix: update-input | ${allDeps}
      name = treefmt-nix
  '';

  # Meta targets
  metaTargets = let
    inputList = builtins.concatStringsSep " " allInputTargets;
    allList = builtins.concatStringsSep " " (allNonTreefmtTargets ++ ["update-treefmt-nix"]);
  in ''
    build update-inputs: phony | ${inputList}
    build update-all: phony | ${allList}
    build update-report: report | update-all

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
