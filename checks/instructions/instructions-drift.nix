# Drift check — every TRACKED generated file must match what writes it.
#
# Two writers, two comparisons:
#
#   * The agent instruction files (AGENTS.md, .github/instructions/) are
#     `ai.*`'s own read-only copies. The expected
#     files are the ones its writers' plans point at for THIS repository's
#     configuration (dev/ai.nix), evaluated the way devenv evaluates it: the
#     built files in each runtime's Markdown tree, already formatted by the
#     house formatter and checked there. No second renderer exists to agree
#     with: the check reads the one that writes the tree.
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
    drv = self.ciPackages.${system};

    # dev/ai.nix gates interactive package installation on `isCI`; the
    # committed bytes must not depend on who evaluates them. Both
    # values are evaluated and their instruction plans must agree.
    evalRepo = isCI:
      harness.evalDevenvModules [
        (import ../../dev/ai.nix {inherit isCI;})
      ];
    repo = evalRepo false;
    repoCI = evalRepo true;
    # Compare the inputs for tracked instructions. One generated tree can also
    # contain structured files whose CI-only configuration changes its store
    # path while these Markdown bytes remain identical.
    instructionPlans = evaluated:
      map (target: harness.markdownInput evaluated target.path)
      ((composed evaluated).targets ++ (harness.ownPlan "copilot" "files-apply" evaluated).targets);
    # The shared AGENTS.md composer's files, as the files engine writes them.
    composed = harness.ownPlan "internal" "files-apply";
    failedAssertions = map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) repo.config.assertions);
    # Dev skills stay in the root pool until their program migration. Pin the
    # declared gaps they request rather than suppressing those real warnings.
    inherit (import ../../lib/ai/option-paths.nix {inherit lib;}) records;
    expectedWarnings = lib.concatMap (runtime: let
      support = records.${runtime}.surfaceSupport.skills;
    in
      lib.optional (repo.config.ai.${runtime}.enable
        && repo.config.ai.skills != {}
        && !(builtins.elem "devenv" support.backends))
      "ai.skills is set but devenv does not deliver it to ${runtime} (reason: ${support.reason})")
    (builtins.attrNames records);

    agentsMd = (lib.findFirst (target: target.path == "AGENTS.md") (throw "instructions-drift: the composer writes no AGENTS.md") (composed repo).targets).content.source;
    # The Copilot instruction files the files engine copies, as the built files
    # in Copilot's generated tree.
    copilotInstructions = pkgs.linkFarm "expected-github-instructions" (map (target: {
      name = lib.removePrefix ".github/instructions/" target.path;
      path = target.content.source;
    }) (lib.filter (target: lib.hasPrefix ".github/instructions/" target.path) (harness.ownPlan "copilot" "files-apply" repo).targets));

    # Each entry: the tracked path, and the file to compare it against.
    # `regenerate` is the task the failure message names.
    files = [
      {
        label = "AGENTS.md";
        tracked = ../../AGENTS.md;
        generated = agentsMd;
        regenerate = "generate:all";
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
  in {
    instructions-reviewer-policy = let
      expected = [
        "ai-config-scope"
        "ai-module-contract"
        "beads"
        "facets"
        "git"
        "kiro-agents"
        "kiro-settings"
        "mcp-secrets"
        "mcp-services"
        "microvm"
        "open-keys"
        "packaging"
      ];
      copilotPaths = map (target: target.path) (harness.ownPlan "copilot" "files-apply" repo).targets;
      localRuntimes = ["claude" "codex" "kimchi" "kiro"];
      localRules = runtime: repo.config.ai.${runtime}.normalized.rules;
      optionPaths = import ../../lib/ai/option-paths.nix {inherit lib;};
      fragmentOverride = runtime: rule: lib.setAttrByPath (optionPaths.pool runtime "rules" ++ ["packaging"]) rule;
      shadowAllowed = overrides: let
        evaluated = harness.evalDevenvModules [
          (import ../../dev/ai.nix {isCI = true;})
          overrides
        ];
      in
        (lib.findFirst (assertion: lib.hasPrefix "dev/ai.nix:" assertion.message) (throw "missing fragment-shadow assertion") evaluated.config.assertions).assertion;
      observation = {
        reviewerRules = builtins.attrNames repo.config.ai.copilot.github.normalized.rules;
        reviewerPaths = copilotPaths;
        localFragments = lib.genAttrs localRuntimes (runtime:
          lib.all (name: let
            root = repo.config.ai.rules.${name};
            local = (localRules runtime).${name};
          in
            local.text == root.text && local.matcher == root.matcher && local.references == root.references)
          (builtins.attrNames repo.config.ai.rules));
        localRouters = lib.genAttrs localRuntimes (runtime:
          lib.all (name: builtins.hasAttr name (localRules runtime))
          (["delegate-routing-router" "peer-communication-router" "stacked-workflows-router"] ++ lib.optional (runtime != "kimchi") "semble"));
        disablesAllowed = shadowAllowed (lib.foldl' lib.recursiveUpdate {} (
          map (runtime: fragmentOverride runtime {enable = false;}) (builtins.attrNames optionPaths.records)
        ));
        disabledReplacementRejected =
          !(shadowAllowed (fragmentOverride "copilot" {
            enable = false;
            text = "Replacement fragment.";
          }));
        sourceReplacementRejected =
          !(shadowAllowed (fragmentOverride "claude" {
            enable = false;
            source = ../../dev/ai.nix;
          }));
      };
    in
      (harness.mkTest "instructions-reviewer-policy" (
        observation.reviewerRules
        == expected
        && copilotPaths == map (name: ".github/instructions/${name}.instructions.md") expected
        && lib.all (value: value) (builtins.attrValues observation.localFragments)
        && lib.all (value: value) (builtins.attrValues observation.localRouters)
        && observation.disablesAllowed
        && observation.disabledReplacementRejected
        && observation.sourceReplacementRejected
      ))
      // {passthru = {inherit observation;};};

    instructions-drift = assert lib.assertMsg (instructionPlans repo == instructionPlans repoCI)
    "instructions-drift: dev/ai.nix writes different instruction files when isCI is set; the committed bytes must not depend on the environment.";
    assert lib.assertMsg (failedAssertions == [])
    "instructions-drift: dev/ai.nix fails its own module assertions:\n${lib.concatStringsSep "\n" failedAssertions}";
    assert lib.assertMsg (!(lib.hasInfix "/bin/ai-markdown-window-notice" repo.config.enterShell))
    "instructions-drift: Codex's launcher owns the document warning; shell entry must not duplicate it.";
    # No instruction or other request may be dropped beyond the declared
    # root-skill gaps above; the warning matrix separately verifies their cause.
    assert lib.assertMsg (lib.sort lib.lessThan repo.config.warnings == lib.sort lib.lessThan expectedWarnings)
    "instructions-drift: dev/ai.nix warns:\n${lib.concatStringsSep "\n" repo.config.warnings}";
      pkgs.runCommand "instructions-drift" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        diff="${pkgs.diffutils}/bin/diff"
        sed="${pkgs.gnused}/bin/sed"
        tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
        failed=0

        ${builtins.concatStringsSep "\n" (map compareOne files)}

        agentsMd=${agentsMd}
        ${lib.concatMapStrings endsInWindow windowNeedles}

        # The Copilot instruction files are compared as a TREE rather than
        # file by file: a fragment that is renamed away, or a new one that
        # was never committed, changes the SET of files. Comparing only the
        # names we happen to list here would miss both.
        if ! "$diff" -r -u "${../../.github/instructions}" \
          "${copilotInstructions}" >"$tmp/diff-dir" 2>&1; then
          failed=1
          echo "" >&2
          echo "DRIFT: .github/instructions/" >&2
          echo "  regenerate with: devenv tasks run --mode before generate:all" >&2
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
