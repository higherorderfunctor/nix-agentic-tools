# config/generate-update-ninja.nix — generate .update.ninja from update-matrix + flake.lock.
#
# Reads flake.lock for input follows relationships and update-matrix.nix
# for package update flags. Outputs a ninja build file with the full DAG.
#
# Usage: nix eval --raw --impure --expr 'import ./config/generate-update-ninja.nix {}'
{
  flakeLock ? builtins.fromJSON (builtins.readFile ../flake.lock),
  updateMatrix ? import ./update-matrix.nix,
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

  # Package dependencies beyond just nixpkgs
  # Rust packages depend on rust-overlay; all nix-update packages depend on nix-update input
  pkgDeps = name: let
    baseDeps = ["update-nixpkgs" "update-nix-update"];
    rustDeps =
      if builtins.elem name ["agnix" "git-absorb" "git-branchless"]
      then ["update-rust-overlay"]
      else [];
  in
    baseDeps ++ rustDeps;

  # treefmt-nix runs last — depends on ALL other targets
  allInputTargets = map (n: "update-${n}") (builtins.filter (n: n != "treefmt-nix") inputNames);
  allPkgTargets =
    builtins.attrValues
    (builtins.mapAttrs (name: _: "update-${name}") updateMatrix.nixUpdate);
  # Remove any-buddy and claude-code from individual targets (handled by combo)
  filteredPkgTargets =
    builtins.filter
    (t: t != "update-any-buddy" && t != "update-claude-code")
    allPkgTargets;
  allNonTreefmtTargets = allInputTargets ++ filteredPkgTargets ++ ["update-any-buddy-claude-code"];

  # Ninja rules
  rules = ''
    # Rules
    rule pipeline-init
      command = bash dev/scripts/update-init.sh
      description = Pipeline init

    rule update-input
      command = bash dev/scripts/update-input.sh $name
      description = Updating input: $name

    rule update-pkg
      command = bash dev/scripts/update-pkg.sh $name $flags
      description = Updating package: $name

    rule update-combo
      command = bash dev/scripts/update-combo.sh
      description = Updating combo: any-buddy + claude-code

    rule full-format
      command = bash -c 'treefmt && git add -A && git diff --staged --quiet || git commit -m "style: treefmt full reformat after updates"'
      description = Full treefmt (formatter config may have changed)

    rule final-build
      command = bash -c 'nix run --inputs-from . nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.$$(nix eval --impure --raw --expr builtins.currentSystem)"'
      description = Final build verification (should be cached)

    rule report
      command = bash dev/scripts/update-report.sh
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
  pkgTargets = builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: flags: let
    deps = pkgDeps name;
    depStr = " | ${builtins.concatStringsSep " " deps}";
  in
    # Skip any-buddy and claude-code (handled by combo target)
    if builtins.elem name ["any-buddy" "claude-code"]
    then ""
    else ''
      build update-${name}: update-pkg${depStr}
        name = ${name}
        flags = ${flags}
    '')
  updateMatrix.nixUpdate));

  # Combo target (any-buddy + claude-code)
  comboTarget = ''
    build update-any-buddy-claude-code: update-combo | update-init update-nixpkgs update-nix-update
  '';

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
    "# Combo: any-buddy + claude-code"
    comboTarget
    ""
    "# treefmt last (isolation)"
    treefmtTarget
    ""
    "# Meta targets"
    metaTargets
  ];
in
  ninja
