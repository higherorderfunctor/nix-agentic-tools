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

  # `full-format` has to keep FOUR outcomes distinct, and every convenient
  # one-liner collapses at least two of them:
  #
  #   1. formatter fails            -> fail the target, commit nothing
  #   2. diff exits 0 (no changes)  -> no commit, NO failure (a real no-op)
  #   3. diff exits 1 (changes)     -> commit
  #   4. diff exits >1 (git ERROR)  -> fail the target, commit nothing
  #
  # `git diff --quiet` is a THREE-valued signal, not a boolean: 0 = no
  # difference, 1 = difference, >1 (commonly 128) = git itself failed. Both
  # earlier shapes read it as a boolean, and both therefore routed a failure
  # into the commit branch.
  #
  # The body was originally `nix fmt && git add -A && git diff --staged
  # --quiet || git commit -m ...`, which parses as `((A && B) && C) || D`
  # because `&&` and `||` share precedence and associate left. A FAILING
  # `nix fmt` therefore fell through to the COMMIT. `errexit` does not
  # rescue that: by design it never fires for a command on the left of
  # `||`, which is exactly why it survived the commit that added
  # strictPrelude to all six rule bodies. The prelude is not, and cannot
  # be, the fix here.
  #
  # Measured on that shape: with anything already in the index, a broken
  # formatter produced an exit-0 target carrying a "style: treefmt full
  # reformat after updates" commit that reformatted nothing — green sweep,
  # unformatted repo. With a clean index it failed only by ACCIDENT, because
  # the fall-through `git commit` then errored on an empty index; that is
  # git refusing to make an empty commit, not the pipeline detecting
  # anything, and it reports the formatter error as "nothing to commit".
  #
  # Replacing it with `if ! git diff --staged --quiet; then git commit ...`
  # fixed outcome 1 but NOT outcome 4: `!` maps every non-zero status to
  # "true", so an erroring `git diff` still selected the commit branch.
  # Measured on that shape too — with `git diff` forced to exit 128 the
  # target exited 0 and carried the same bogus style commit. The
  # failure-becomes-a-commit path had been narrowed, not closed.
  #
  # The fix keeps the `;` separators (which put `nix fmt` and `git add -A`
  # back under errexit) and replaces the boolean test with an explicit
  # status capture. `|| rc=$$?` is the one place errexit is suppressed, so
  # the ordinary exit-1 path cannot kill the target, and the `case` then
  # discriminates all three diff statuses by value instead of by
  # truthiness.
  #
  # NINJA ESCAPING: `$$` is mandatory. Ninja owns `$` in a `command =`
  # value — a bare `$rc` silently expands to the empty ninja variable, and
  # a bare `$?` is a hard parse error ("bad $-escape") that takes the
  # WHOLE .update.ninja down, not just this rule. `$$` is ninja's literal
  # `$`, so the shell receives `rc=$?` / `"$rc"`. Verified both ways.
  fullFormatBody = ''nix fmt; git add -A; rc=0; git diff --staged --quiet || rc=$$?; case "$$rc" in 0) ;; 1) git commit -m "style: treefmt full reformat after updates" ;; *) exit "$$rc" ;; esac;'';

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

    rule full-format
      command = bash -c '${strictPrelude} { ${fullFormatBody} } 2>&1 | tee .update-logs/full-format.log'
      description = Full treefmt (formatter config may have changed)

    rule final-build
      command = bash -c '${strictPrelude} source dev/scripts/update-common.sh; verify_all_packages 2>&1 | tee .update-logs/final-build.log'
      description = Final build verification (should be cached)

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
