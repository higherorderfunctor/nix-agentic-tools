# Drift check — every TRACKED generated file must match what writes it.
#
# Two writers, two comparisons:
#
#   * The agent instruction files (AGENTS.md, .github/copilot-instructions.md,
#     .github/instructions/) are `ai.*`'s own read-only copies. The expected
#     files are the ones its writers' plans point at for THIS repository's
#     configuration (dev/ai.nix), evaluated the way devenv evaluates it: the
#     built files in each runtime's Markdown tree. No second renderer exists
#     to agree with: the check reads the one that writes the tree.
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

    # dev/ai.nix gates Semble's install on `isCI`, and nothing else may read
    # it: the committed bytes must not depend on who evaluates them. Both
    # values are evaluated and their instruction plans must agree.
    evalRepo = isCI: harness.evalDevenvModules [(import ../../dev/ai.nix {inherit isCI;})];
    repo = evalRepo false;
    repoCI = evalRepo true;
    instructionPlans = evaluated:
      map (target: lib.mapAttrs (_: unit: unit.store or unit.text or null) target.units) (
        (harness.ownPlan "internal" "ai:agents-md:materialize" evaluated).targets
        ++ (harness.ownPlan "copilot" "ai:copilot:materialize-instructions" evaluated).targets
      );
    failedAssertions = map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) repo.config.assertions);

    # Each unit one writer's directory target will write, as the file it
    # copies: the built file a Markdown unit points at, or its inline text.
    unitsAt = runtime: writer: path: let
      targets = lib.filter (target: target.path == path) (harness.ownPlan runtime writer repo).targets;
    in
      if builtins.length targets != 1
      then throw "instructions-drift: expected one ${runtime} target at ${path}, found ${toString (builtins.length targets)}"
      else lib.mapAttrs (address: unit: unit.store or (pkgs.writeText address unit.text)) (builtins.head targets).units;
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

    # Codex reads only the first 32 KiB of AGENTS.md wherever this
    # repository's raised `project_doc_max_bytes` is absent or untrusted (a
    # fresh clone, a linked worktree). The index and every inlined rule must
    # end inside that window; only the orientation's tail may fall past it.
    # Measured on the built file, as byte offsets.
    codexDefaultLimit = 32768;
    windowNeedles =
      ["Before editing a path that matches an entry below, read every document listed"]
      ++ map (key: "<!-- rule: ${key} -->") (builtins.attrNames repo.config.ai.internal.agentsMd."AGENTS.md".rules);
    endsInWindow = needle: ''
      if ! hit="$(grep -b -o -F -m 1 -e ${lib.escapeShellArg needle} "$agentsMd")"; then
        failed=1
        echo "AGENTS.md does not contain: "${lib.escapeShellArg needle} >&2
      elif [ "$(( ''${hit%%:*} + ${toString (builtins.stringLength needle)} ))" -gt ${toString codexDefaultLimit} ]; then
        failed=1
        echo "AGENTS.md puts this past Codex's default ${toString codexDefaultLimit}-byte read limit: "${lib.escapeShellArg needle} >&2
      fi
    '';
    # dev/ai.nix raises Codex's limit, so an untrusted Codex reads only the
    # first 32 KiB, and every shell entry runs the window notice on the
    # project's AGENTS.md. These are those lines, run below against the built
    # file: the notice must fire exactly while the file is past the window.
    noticeLines = lib.filter (lib.hasInfix "/bin/ai-markdown-window-notice ") (lib.splitString "\n" repo.config.enterShell);
  in {
    instructions-drift = assert lib.assertMsg (instructionPlans repo == instructionPlans repoCI)
    "instructions-drift: dev/ai.nix writes different instruction files when isCI is set; the committed bytes must not depend on the environment.";
    assert lib.assertMsg (failedAssertions == [])
    "instructions-drift: dev/ai.nix fails its own module assertions:\n${lib.concatStringsSep "\n" failedAssertions}";
    assert lib.assertMsg (builtins.length noticeLines == 1)
    "instructions-drift: dev/ai.nix raises Codex's limit, so shell entry must run exactly one AGENTS.md window notice, found:\n${lib.concatStringsSep "\n" noticeLines}";
    # The repository's own configuration evaluates without a warning: no
    # context or rule it asks for lands in a file it has switched off, or
    # anywhere `ai.*` cannot deliver it.
    assert lib.assertMsg (repo.config.warnings == [])
    "instructions-drift: dev/ai.nix warns:\n${lib.concatStringsSep "\n" repo.config.warnings}";
      pkgs.runCommand "instructions-drift" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        diff="${pkgs.diffutils}/bin/diff"
        sed="${pkgs.gnused}/bin/sed"
        tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
        failed=0

        ${builtins.concatStringsSep "\n" (map compareOne files)}

        agentsMd=${agentsMd."AGENTS.md"}
        ${lib.concatMapStrings endsInWindow windowNeedles}

        # The shell-entry notice, as devenv runs it, on the built file.
        DEVENV_ROOT="$tmp/root"
        mkdir -p "$DEVENV_ROOT"
        cp "$agentsMd" "$DEVENV_ROOT/AGENTS.md"
        ${lib.concatStringsSep "\n" noticeLines} 2>"$tmp/notice"
        if [ "$(wc -c <"$agentsMd")" -gt ${toString codexDefaultLimit} ]; then
          grep -q -F "reads only the first ${toString codexDefaultLimit}" "$tmp/notice" || {
            failed=1
            echo "AGENTS.md is past ${toString codexDefaultLimit} bytes, but the shell-entry notice is silent" >&2
          }
        elif [ -s "$tmp/notice" ]; then
          failed=1
          echo "AGENTS.md is within ${toString codexDefaultLimit} bytes, but the shell-entry notice warns:" >&2
          cat "$tmp/notice" >&2
        fi

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
