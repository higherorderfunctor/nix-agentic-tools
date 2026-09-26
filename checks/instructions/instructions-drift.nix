# Drift check — every TRACKED generated file must match what writes it.
#
# Two writers, two comparisons:
#
#   * The agent instruction files (AGENTS.md, .github/copilot-instructions.md,
#     .github/instructions/) are `ai.*`'s own read-only copies. The expected
#     bytes are the units its writers' plans carry for THIS repository's
#     configuration (dev/ai.nix), evaluated the way devenv evaluates it. No
#     second renderer exists to agree with: the check reads the one that
#     writes the tree.
#   * README.md and CONTRIBUTING.md are human documents dev/generate.nix
#     renders; the `repo-*` packages are what `generate:repo:*` copies out.
#
# The gitignored instruction files (.claude/, .kiro/steering/) have no
# tracked bytes to compare; enterTest asserts they land as files.
#
# Why it exists: nothing else asserted tracked generated files matched their
# source. Both repo-root documents once drifted far enough to be wrong —
# README.md's install example set an option that did not exist, and
# CONTRIBUTING.md told contributors to add an nvfetcher entry, a workflow the
# repo forbids.
#
# Living in `nix flake check` is deliberate: it is the repo's validation
# entrypoint, covered by the required `build`/`test` status checks, with no
# path filter to fall through.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    drv = self.packages.${system};

    # `isCI` is pinned: Semble (and so its AGENTS.md rule) is gated on it, and
    # the committed bytes must not depend on who evaluates them.
    repo = harness.evalDevenvModules [(import ../../dev/ai.nix {isCI = false;})];
    failedAssertions = map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) repo.config.assertions);
    # The repository's own configuration drops nothing: no context or rule it
    # asks for lands in a file it has switched off, or anywhere `ai.*` cannot
    # deliver it.
    deliveryWarnings = lib.filter (lib.hasInfix "does not deliver it to") repo.config.warnings;

    # The units one writer's directory target will write, as files.
    unitsAt = runtime: writer: path: let
      targets = lib.filter (target: target.path == path) (harness.ownPlan runtime writer repo).targets;
    in
      if builtins.length targets != 1
      then throw "instructions-drift: expected one ${runtime} target at ${path}, found ${toString (builtins.length targets)}"
      else
        lib.mapAttrs (address: unit:
          pkgs.writeText address (
            unit.text
            or (throw "instructions-drift: ${path}/${address} is not inline text")
          ))
        (builtins.head targets).units;
    agentsMd = unitsAt "internal" "ai:agents-md:materialize" ".";
    copilotContext = unitsAt "copilot" "ai:copilot:materialize-instructions" ".github";
    copilotInstructions = pkgs.linkFarm "expected-github-instructions" (unitsAt "copilot" "ai:copilot:materialize-instructions" ".github/instructions");

    # Each entry: the tracked path, and the file to compare it against.
    # `regenerate` is the task the failure message names.
    files = [
      {
        label = "AGENTS.md";
        tracked = ../../AGENTS.md;
        generated = agentsMd."AGENTS.md";
        regenerate = "generate:instructions";
      }
      {
        label = "CONTRIBUTING.md";
        tracked = ../../CONTRIBUTING.md;
        generated = "${drv.repo-contributing}/CONTRIBUTING.md";
        regenerate = "generate:repo:contributing";
      }
      {
        label = "README.md";
        tracked = ../../README.md;
        generated = "${drv.repo-readme}/README.md";
        regenerate = "generate:repo:readme";
      }
      {
        label = ".github/copilot-instructions.md";
        tracked = ../../.github/copilot-instructions.md;
        generated = copilotContext."copilot-instructions.md";
        regenerate = "generate:instructions";
      }
    ];

    # `2>&1` so a diff-level error (a missing path, a permission fault)
    # lands in the captured output too — otherwise it goes to the real
    # stderr and the printed diff is blank, hiding why the check failed.
    compareOne = f: ''
      if ! "$diff" -u "${f.tracked}" "${f.generated}" >"$tmp/diff" 2>&1; then
        failed=1
        echo "" >&2
        echo "DRIFT: ${f.label}" >&2
        echo "  regenerate with: devenv tasks run --mode before ${f.regenerate}" >&2
        "$sed" -n '1,80p' "$tmp/diff" >&2
      fi
    '';
  in {
    instructions-drift = assert lib.assertMsg (failedAssertions == [])
    "instructions-drift: dev/ai.nix fails its own module assertions:\n${lib.concatStringsSep "\n" failedAssertions}";
    assert lib.assertMsg (deliveryWarnings == [])
    "instructions-drift: dev/ai.nix asks for content ai.* does not deliver:\n${lib.concatStringsSep "\n" deliveryWarnings}";
      pkgs.runCommand "instructions-drift" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        diff="${pkgs.diffutils}/bin/diff"
        sed="${pkgs.gnused}/bin/sed"
        tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
        failed=0

        ${builtins.concatStringsSep "\n" (map compareOne files)}

        # The Copilot instruction files are compared as a TREE rather than
        # file by file: a fragment that is renamed away, or a new one that
        # was never committed, changes the SET of files. Comparing only the
        # names we happen to list here would miss both.
        if ! "$diff" -r -u "${../../.github/instructions}" \
          "${copilotInstructions}" >"$tmp/diff-dir" 2>&1; then
          failed=1
          echo "" >&2
          echo "DRIFT: .github/instructions/" >&2
          echo "  regenerate with: devenv tasks run --mode before generate:instructions" >&2
          "$sed" -n '1,80p' "$tmp/diff-dir" >&2
        fi

        if [ "$failed" -ne 0 ]; then
          echo "" >&2
          echo "Tracked generated files are out of sync with what writes them." >&2
          echo "Regenerate, then 'git add' the results — flakes only see tracked files." >&2
          exit 1
        fi

        echo "ok — every tracked generated file matches its writer" > $out
      '';
  };
}
