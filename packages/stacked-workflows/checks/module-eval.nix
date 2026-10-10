# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
in {
  checks = {
    # ── Stacked-workflows: skills + router, user-global (HM) + project (devenv) ──
    # The HM module installs the unprefixed stack-* skills + skill-routing rule
    # user-global; the devenv module mirrors them project-local. References are
    # bundled as REAL files inside each skill dir (deref'd at build).

    # Default disabled — the portable program enable defaults to false.
    module-sws-default-disabled = mkTest "sws-default-disabled" (
      let
        result = evalHm {};
      in
        !result.config.ai.programs.stacked-workflows.enable
        && !(result.options.stacked-workflows ? enable)
    );

    # ── Where these contributions land ────────────────────────────────────
    #
    # The skill packages write the PER-RUNTIME pools (`ai.<runtime>.skills`,
    # `ai.<runtime>.rules`), never the root ones. The tests below assert
    # both halves of that, and the second half is the one worth having: a root
    # package write would silently fan out beyond package runtime ownership, so a
    # regression could still deliver every skill and pass a presence-only test.
    #
    # They iterate `harnessNames` (the shared registry) rather than sampling one
    # runtime, so a sixth runtime is covered the day it is added.

    # Devenv scope: enable -> every runtime's pool gets the unprefixed stack-*
    # skills, and the root pool gets none of them.
    module-sws-devenv-enable-sets-ai-skills = mkTest "sws-devenv-enable-sets-ai-skills" (
      let
        result = evalDevenv {ai.programs.stacked-workflows.enable = true;};
        expected = ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"];
        runtimeHasAll = runtime:
          lib.all (skill: result.config.ai.${runtime}.skills ? ${skill}) expected;
      in
        lib.all runtimeHasAll harnessNames
        && !(result.config.ai.skills ? stack-fix)
    );

    # Devenv scope: the router rule lands in every supporting runtime's pool and
    # not in the root pool.
    module-sws-devenv-enable-sets-ai-rules = mkTest "sws-devenv-enable-sets-ai-rules" (
      let
        result = evalDevenv {ai.programs.stacked-workflows.enable = true;};
        ruleRuntimes = builtins.filter (runtime: result.options.ai.${runtime} ? rules) harnessNames;
        runtimeHasOne = runtime: result.config.ai.${runtime}.rules ? stacked-workflows-router;
      in
        lib.all runtimeHasOne ruleRuntimes
        && !(result.config.ai.rules ? stacked-workflows-router)
    );

    # HM (user-global) scope: enable -> every runtime's pool gets the unprefixed
    # stack-* skills, so each enabled CLI installs them to ~/.claude/skills etc.
    # This is the scope-revert (previously the HM module was git-config only).
    module-sws-hm-enable-sets-ai-skills = mkTest "sws-hm-enable-sets-ai-skills" (
      let
        result = evalHm {ai.programs.stacked-workflows.enable = true;};
        expected = ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"];
        runtimeHasAll = runtime:
          lib.all (skill: result.config.ai.${runtime}.skills ? ${skill}) expected;
      in
        lib.all runtimeHasAll harnessNames
        && !(result.config.ai.skills ? stack-fix)
    );

    # HM (user-global) scope: enable -> the skill-routing rule lands in every
    # supporting runtime's pool.
    module-sws-hm-enable-sets-ai-rules = mkTest "sws-hm-enable-sets-ai-rules" (
      let
        result = evalHm {ai.programs.stacked-workflows.enable = true;};
        ruleRuntimes = builtins.filter (runtime: runtime != "copilot" && result.options.ai.${runtime} ? rules) harnessNames;
        runtimeHasOne = runtime: result.config.ai.${runtime}.rules ? stacked-workflows-router;
      in
        lib.all runtimeHasOne ruleRuntimes
        && result.config.ai.copilot.rules == {}
        && !(result.config.ai.rules ? stacked-workflows-router)
    );

    # Package rules are defaults, so a consumer can replace the router for one
    # runtime without creating a definition conflict or affecting its siblings.
    module-sws-consumer-rule-override-wins = mkTest "sws-consumer-rule-override-wins" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          ai.claude.rules.stacked-workflows-router.text = "Consumer router.";
        };
      in
        result.config.ai.claude.rules.stacked-workflows-router.text
        == "Consumer router."
        && result.config.ai.codex.rules.stacked-workflows-router.text != "Consumer router."
    );

    # B4 program negation controls the package's actual per-runtime pool writes.
    # Disabling Codex removes both its skills and router while sibling runtimes
    # continue inheriting the portable enable.
    module-sws-runtime-program-negation = mkTest "sws-runtime-program-negation" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          ai.programs.stacked-workflows.runtimes.codex.enable = false;
        };
      in
        result.config.ai.claude.skills ? stack-fix
        && result.config.ai.claude.rules ? stacked-workflows-router
        && !(result.config.ai.codex.skills ? stack-fix)
        && !(result.config.ai.codex.rules ? stacked-workflows-router)
    );

    # Runtime overrides control runtime pool writes only. A runtime-only enable
    # cannot activate the Git companion when the portable program remains
    # disabled.
    module-sws-git-preset-requires-portable-enable = mkTest "sws-git-preset-requires-portable-enable" (
      let
        config = {
          ai.programs.stacked-workflows.runtimes.codex.enable = true;
          stacked-workflows.gitPreset = "minimal";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        hm.config.programs.git.settings
        == {}
        && !hm.config.git.branchless.enable
        && devenv.config.git.settings == {}
        && !(devenv.config.tasks ? "git:branchless-init")
        && hm.config.ai.codex.skills ? stack-fix
    );

    # Conversely, a runtime negation does not retract Git configuration selected
    # by the portable program enable.
    module-sws-runtime-negation-keeps-git-preset = mkTest "sws-runtime-negation-keeps-git-preset" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          ai.programs.stacked-workflows.runtimes.codex.enable = false;
          stacked-workflows.gitPreset = "minimal";
        };
      in
        result.config.programs.git.settings.pull.rebase
        && !(result.config.ai.codex.skills ? stack-fix)
    );

    # The presets are sugar over `git.*`. Against the preset data frozen at
    # cd934bb4, the rendered configuration on BOTH backends differs by
    # exactly the approved changes: branchless.core.mainBranch gone from
    # both, fetch.pruneTags gone from full, alias.sync (scopedSync) added to
    # full. Every other leaf is byte-identical.
    module-sws-presets-approved-diff = mkTest "sws-presets-approved-diff" (
      let
        before = lib.importJSON ./fixtures/git-presets-cd934bb4.json;
        approved = {
          full = {
            added = {"alias.sync" = "branchless sync 'stack()'";};
            removed = ["branchless.core.mainBranch" "fetch.pruneTags"];
          };
          minimal = {
            added = {};
            removed = ["branchless.core.mainBranch"];
          };
        };
        leaves = attrs:
          lib.listToAttrs (lib.collect (x: x ? name) (lib.mapAttrsRecursive (path: value: {
              name = lib.concatStringsSep "." path;
              inherit value;
            })
            attrs));
        rendered = backend: preset: let
          config = {
            ai.programs.stacked-workflows.enable = true;
            stacked-workflows.gitPreset = preset;
          };
        in
          if backend == "hm"
          then (evalHm config).config.programs.git.settings
          else (evalDevenv config).config.git.settings;
        diffOf = old: new: {
          added = removeAttrs new (lib.attrNames old);
          removed = lib.attrNames (removeAttrs old (lib.attrNames new));
          changed = lib.filter (key: new ? ${key} && new.${key} != old.${key}) (lib.attrNames old);
        };
        nest = flat: lib.foldl' lib.recursiveUpdate {} (lib.mapAttrsToList (key: lib.setAttrByPath (lib.splitString "." key)) flat);
        matches = backend: preset: let
          old = leaves before.${preset};
          new = rendered backend preset;
          diff = diffOf old (leaves new);
          # The old rendering with exactly the approved edits applied.
          expected = removeAttrs old approved.${preset}.removed // approved.${preset}.added;
        in
          diff.added
          == approved.${preset}.added
          && diff.removed == approved.${preset}.removed
          && diff.changed == []
          && lib.generators.toGitINI new == lib.generators.toGitINI (nest expected);
      in
        lib.all (backend: lib.all (matches backend) ["full" "minimal"]) ["devenv" "hm"]
        && rendered "hm" "none" == {}
        && rendered "devenv" "none" == {}
    );

    # One rendering: Home Manager's settings and devenv's included file are the
    # same git configuration for every preset.
    module-sws-presets-hm-devenv-same-ini = mkTest "sws-presets-hm-devenv-same-ini" (
      lib.all (preset: let
        config = {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = preset;
        };
      in
        lib.generators.toGitINI (evalHm config).config.programs.git.settings
        == lib.generators.toGitINI (evalDevenv config).config.git.settings) ["full" "minimal" "none"]
    );

    # Every leaf of a tool's section in the preset data is a typed option
    # (the rest go to `git.settings`), and presets set values at mkDefault:
    # the typed option carries priority 1000 and enables the three tools the
    # same way.
    module-sws-preset-leaves-are-options = mkTest "sws-preset-leaves-are-options" (
      let
        presets = import ../lib/git-presets.nix;
        evaluated = evalHm {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "full";
        };
        tools = ["absorb" "branchless" "revise"];
        typedLeaf = section: path: let
          option = lib.attrByPath path null evaluated.options.git.${section}.settings;
        in
          option != null && lib.isOption option && option.highestPrio == 1000;
        sectionLeaves = section: data:
          lib.collect lib.isList (lib.mapAttrsRecursive (path: _: path) (data.${section} or {}));
      in
        lib.all (preset:
          lib.all (section: lib.all (typedLeaf section) (sectionLeaves section presets.${preset}.settings)) tools)
        (lib.attrNames presets)
        && lib.all (section: evaluated.config.git.${section}.enable && evaluated.options.git.${section}.enable.highestPrio == 1000) tools
        && evaluated.options.git.branchless.scopedSync.highestPrio == 1000
    );

    # pull.ff beats pull.rebase since Git 2.34, so an active preset rejects it
    # on both backends; "none" does not care.
    module-sws-pull-ff-assertion = mkTest "sws-pull-ff-assertion" (
      let
        fails = evaluate: preset: raw:
          lib.any (a: !a.assertion)
          (evaluate ({
              ai.programs.stacked-workflows.enable = true;
              stacked-workflows.gitPreset = preset;
            }
            // raw))
          .config
          .assertions;
      in
        fails evalHm "minimal" {programs.git.settings.pull.ff = "only";}
        && fails evalDevenv "full" {git.settings.pull.ff = "only";}
        && !(fails evalHm "none" {programs.git.settings.pull.ff = "only";})
        && !(fails evalDevenv "minimal" {})
    );

    # devenv: a preset enables git.branchless, so the init task exists; "none"
    # and a disabled portable program leave no init task and nothing rendered.
    module-sws-devenv-preset-tasks = mkTest "sws-devenv-preset-tasks" (
      let
        tasksOf = config: (evalDevenv config).config.tasks;
      in
        (tasksOf {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "minimal";
        })
        ? "git:branchless-init"
        && !((tasksOf {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "none";
        })
        ? "git:branchless-init")
        && (tasksOf {stacked-workflows.gitPreset = "none";}) ? "git:config"
    );

    # References are bundled as REAL files inside each skill dir (deref'd at
    # build) — NOT written as separate .claude/references/* files anymore.
    # This guards the dangling-symlink regression: the skill's references must
    # resolve to real, present files.
    module-sws-skill-references-resolve = mkTest "sws-skill-references-resolve" (
      let
        result = evalDevenv {ai.programs.stacked-workflows.enable = true;};
        skillPath = result.config.ai.claude.skills.stack-fix;
      in
        builtins.pathExists "${skillPath}/SKILL.md"
        && builtins.pathExists "${skillPath}/references/git-absorb.md"
        && builtins.pathExists "${skillPath}/references/git-branchless.md"
    );
  };
}
