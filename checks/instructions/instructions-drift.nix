# Drift check — every TRACKED generated file must match what writes it.
#
# Two writers, two comparisons:
#
#   * The GitHub instruction files (.github/instructions/) are
#     `ai.*`'s own read-only copies. The expected
#     files are the ones its writers' plans point at for THIS repository's
#     configuration (dev/ai.nix), evaluated the way devenv evaluates it: the
#     built files in each runtime's Markdown tree, already formatted by the
#     house formatter and checked there. No second renderer exists to agree
#     with: the check reads the one that writes the tree.
#   * README.md and CONTRIBUTING.md are human documents dev/generate.nix
#     renders; the `repo-*` packages are what `generate:repo:*` copies out.
#
# The local instruction files (AGENTS.md, .agents/rules/, .claude/,
# .kiro/steering/) have no tracked bytes to compare. Their generated composition
# remains checked with an explicit local opt-in fixture.
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
    evalRepo = isCI: extraModules:
      harness.evalDevenvModules (
        [(import ../../dev/ai.nix {inherit isCI;})] ++ extraModules
      );
    repo = evalRepo false [];
    repoCI = evalRepo true [];
    # Exercise the operator's opt-in composition without reading personal config.
    localModules = [./fixtures/local-runtimes.nix];
    localRepo = evalRepo false localModules;
    localRepoCI = evalRepo true localModules;
    evaluations = [localRepo localRepoCI repo repoCI];
    # Compare instruction inputs and destinations. One generated tree can also
    # contain structured files whose CI-only configuration changes its store
    # path while these Markdown bytes remain identical.
    instructionPlans = evaluated:
      map (target: {
        inherit (target) path;
        content = harness.markdownInput evaluated target.path;
      })
      # Copilot-only evaluations have no shared AGENTS.md writer.
      (lib.optionals (evaluated.config.ai.internal.agentsMd != {}) (composed evaluated).targets
        ++ (harness.ownPlan "copilot" "files-apply" evaluated).targets);
    # The shared AGENTS.md composer's files, as the files engine writes them.
    composed = harness.ownPlan "internal" "files-apply";
    failedAssertions = lib.concatMap (evaluated:
      map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) evaluated.config.assertions))
    evaluations;
    # Dev skills stay in the root pool until their program migration. Pin the
    # declared gaps they request rather than suppressing those real warnings.
    inherit (import ../../lib/ai/option-paths.nix {inherit lib;}) records;
    expectedWarnings = evaluated:
      lib.concatMap (runtime: let
        support = records.${runtime}.surfaceSupport.skills;
      in
        lib.optional (evaluated.config.ai.${runtime}.enable
          && evaluated.config.ai.skills != {}
          && !(builtins.elem "devenv" support.backends))
        "ai.skills is set but devenv does not deliver it to ${runtime} (reason: ${support.reason})")
      (builtins.attrNames records);

    agentsMd = (lib.findFirst (target: target.path == "AGENTS.md") (throw "instructions-drift: the composer writes no AGENTS.md") (composed localRepo).targets).content.source;
    # The Copilot instruction files the files engine copies, as the built files
    # in Copilot's generated tree.
    copilotInstructions = pkgs.linkFarm "expected-github-instructions" (map (target: {
      name = lib.removePrefix ".github/instructions/" target.path;
      path = target.content.source;
    }) (lib.filter (target: lib.hasPrefix ".github/instructions/" target.path) (harness.ownPlan "copilot" "files-apply" repo).targets));

    copilotContext = lib.findFirst (target: target.path == ".github/copilot-instructions.md") null (harness.ownPlan "copilot" "files-apply" repo).targets;

    # Each entry: the tracked path, and the file to compare it against.
    # `regenerate` is the task the failure message names.
    files =
      [
        {
          label = ".github/instructions/";
          tracked = ../../.github/instructions;
          generated = copilotInstructions;
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
      ]
      ++ lib.optional (copilotContext != null) {
        label = ".github/copilot-instructions.md";
        tracked = "${self}/.github/copilot-instructions.md";
        generated = copilotContext.content.source;
        regenerate = "generate:all";
      };

    # `2>&1` so a diff-level error (a missing path, a permission fault)
    # lands in the captured output too — otherwise it goes to the real
    # stderr and the printed diff is blank, hiding why the check failed.
    compareOne = f: ''
      if ! "$diff" -r -u "${f.tracked}" "${f.generated}" >"$tmp/diff" 2>&1; then
        failed=1
        echo "" >&2
        echo "DRIFT: ${f.label}" >&2
        echo "  regenerate with: devenv tasks run --mode before ${f.regenerate}" >&2
        "$sed" -n '1,80p' "$tmp/diff" >&2
      fi
    '';

    # Local documents are generated alongside their runtime configuration.
    # Check the complete built composition against the configured byte budget;
    # the composer's generated tree also enforces each target's maxBytes.
    codexLimit = localRepo.config.ai.codex.projectDocMaxBytes;
    ruleNeedles = map (key: "<!-- rule: ${key} -->") (builtins.attrNames localRepo.config.ai.internal.agentsMd."AGENTS.md".rules);
    containsRule = needle: ''
      if ! grep -q -F -e ${lib.escapeShellArg needle} "$agentsMd"; then
        failed=1
        echo "AGENTS.md does not contain: "${lib.escapeShellArg needle} >&2
      fi
    '';
  in {
    instructions-reviewer-policy = let
      expected = [
        "ai-config-scope"
        "ai-module-contract"
        "beads"
        "coding-standards"
        "commit-convention"
        "config-parity"
        "facets"
        "git"
        "kiro-agents"
        "kiro-settings"
        "mcp-secrets"
        "mcp-services"
        "microvm"
        "open-keys"
        "packaging"
        "project-overview"
      ];
      sharedAlways = [
        "architecture"
        "build-commands"
        "change-propagation"
        "coding-standards"
        "commit-convention"
        "config-parity"
        "operating-policy"
        "project-overview"
        "tooling-preference"
        "validation"
      ];
      reviewerAlways = ["coding-standards" "commit-convention" "config-parity" "project-overview"];
      copilotPaths = map (target: target.path) (harness.ownPlan "copilot" "files-apply" repo).targets;
      localRuntimes = ["claude" "codex" "kimchi" "kiro"];
      localRules = runtime: localRepo.config.ai.${runtime}.normalized.rules;
      optionPaths = import ../../lib/ai/option-paths.nix {inherit lib;};
      fragmentOverride = runtime: rule: lib.setAttrByPath (optionPaths.pool runtime "rules" ++ ["packaging"]) rule;
      shadowAllowed = overrides: let
        evaluated = evalRepo true (localModules ++ [overrides]);
      in
        (lib.findFirst (assertion: lib.hasPrefix "dev/ai.nix:" assertion.message) (throw "missing fragment-shadow assertion") evaluated.config.assertions).assertion;
      observation = {
        disabledReplacementRejected =
          !(shadowAllowed (fragmentOverride "copilot" {
            enable = false;
            text = "Replacement fragment.";
          }));
        disablesAllowed = shadowAllowed (lib.foldl' lib.recursiveUpdate {} (
          map (runtime: fragmentOverride runtime {enable = false;}) (builtins.attrNames optionPaths.records)
        ));
        independentCopilot = lib.all (evaluated:
          !(evaluated.config.ai.internal.agentsMdTargets ? copilot)
          && lib.all (target:
            lib.all (audience: !(builtins.elem "copilot" audience)) (builtins.attrValues target.audiences))
          (builtins.attrValues evaluated.config.ai.internal.agentsMd))
        [repo localRepo];
        localCopilotUnchanged =
          (harness.ownPlan "copilot" "files-apply" repo).targets
          == (harness.ownPlan "copilot" "files-apply" localRepo).targets;
        localFragments = lib.genAttrs localRuntimes (runtime:
          lib.all (name: let
            root = localRepo.config.ai.rules.${name};
            local = (localRules runtime).${name};
          in
            local.text == root.text && local.matcher == root.matcher && local.references == root.references)
          (builtins.attrNames localRepo.config.ai.rules));
        localRouters = lib.genAttrs localRuntimes (runtime:
          lib.all (name: builtins.hasAttr name (localRules runtime))
          (["peer-communication-router"] ++ lib.optional (runtime != "kimchi") "semble"));
        namedComposition =
          localRepo.config.ai.internal.agentsMd."AGENTS.md".context
          == null
          && lib.all (name: builtins.hasAttr name localRepo.config.ai.internal.agentsMd."AGENTS.md".rules) sharedAlways;
        reviewerAlways = lib.all (name:
          lib.hasInfix ''applyTo: "**"'' (harness.markdownInput repo ".github/instructions/${name}.instructions.md").text)
        reviewerAlways;
        reviewerPaths = copilotPaths;
        reviewerRules = builtins.attrNames repo.config.ai.copilot.github.normalized.rules;
        runtimeOptIn =
          repo.config.ai.copilot.enable
          && localRepo.config.ai.copilot.enable
          && lib.all (runtime: !repo.config.ai.${runtime}.enable && localRepo.config.ai.${runtime}.enable) localRuntimes
          && lib.all (program: !repo.config.ai.programs.${program}.enable && localRepo.config.ai.programs.${program}.enable) ["peer-communication" "semble"];
        sharedAlways = lib.all (name:
          repo.config.ai.rules.${name}.inclusion
          == ["always"]
          && repo.config.ai.rules.${name}.matcher == null)
        sharedAlways;
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
        && observation.runtimeOptIn
        && observation.localCopilotUnchanged
        && observation.independentCopilot
        && observation.namedComposition
        && observation.reviewerAlways
        && observation.sharedAlways
        && lib.all (value: value) (builtins.attrValues observation.localFragments)
        && lib.all (value: value) (builtins.attrValues observation.localRouters)
        && observation.disablesAllowed
        && observation.disabledReplacementRejected
        && observation.sourceReplacementRejected
      ))
      // {passthru = {inherit observation;};};

    instructions-drift = assert lib.assertMsg (copilotContext != null || !(builtins.pathExists "${self}/.github/copilot-instructions.md"))
    "instructions-drift: tracked .github/copilot-instructions.md has no generated writer; remove the stale instruction file.";
    assert lib.assertMsg (instructionPlans repo == instructionPlans repoCI && instructionPlans localRepo == instructionPlans localRepoCI)
    "instructions-drift: dev/ai.nix writes different instruction files when isCI is set; the committed bytes must not depend on the environment.";
    assert lib.assertMsg (failedAssertions == [])
    "instructions-drift: dev/ai.nix fails its own module assertions:\n${lib.concatStringsSep "\n" failedAssertions}";
    assert lib.assertMsg (lib.all (evaluated: !(lib.hasInfix "/bin/ai-markdown-window-notice" evaluated.config.enterShell)) evaluations)
    "instructions-drift: Codex's launcher owns the document warning; shell entry must not duplicate it.";
    # No instruction or other request may be dropped beyond the declared
    # root-skill gaps above; the warning matrix separately verifies their cause.
    assert lib.assertMsg (lib.all (evaluated: lib.sort lib.lessThan evaluated.config.warnings == lib.sort lib.lessThan (expectedWarnings evaluated)) evaluations)
    "instructions-drift: dev/ai.nix warns:\n${lib.concatMapStringsSep "\n" (evaluated: lib.concatStringsSep "\n" evaluated.config.warnings) evaluations}";
      pkgs.runCommand "instructions-drift" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        diff="${pkgs.diffutils}/bin/diff"
        sed="${pkgs.gnused}/bin/sed"
        tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
        failed=0

        ${builtins.concatStringsSep "\n" (map compareOne files)}

        agentsMd=${agentsMd}
        ${lib.concatMapStrings containsRule ruleNeedles}
        if [ "$(wc -c < "$agentsMd")" -gt ${toString codexLimit} ]; then
          failed=1
          echo "AGENTS.md exceeds Codex's configured ${toString codexLimit}-byte read limit" >&2
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
