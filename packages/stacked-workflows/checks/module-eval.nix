# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  harness,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalDevenvModules evalHm harnessNames mkTest;
  presetPath = ".devenv/stacked-workflows.gitconfig";
  sharedGitConfig = import ../lib/git-presets.nix;
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
        ruleRuntimes = builtins.filter (runtime: result.options.ai.${runtime} ? rules) harnessNames;
        runtimeHasOne = runtime: result.config.ai.${runtime}.rules ? stacked-workflows-router;
      in
        lib.all runtimeHasOne ruleRuntimes
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
          ai.codex.programs.stacked-workflows.enable = false;
        };
      in
        result.config.ai.claude.skills ? stack-fix
        && result.config.ai.claude.rules ? stacked-workflows-router
        && !(result.config.ai.codex.skills ? stack-fix)
        && !(result.config.ai.codex.rules ? stacked-workflows-router)
    );

    # Runtime overrides control runtime pool writes only. A runtime-only enable
    # cannot activate the machine-wide Git companion when the portable program
    # remains disabled.
    module-sws-git-preset-requires-portable-enable = mkTest "sws-git-preset-requires-portable-enable" (
      let
        result = evalHm {
          ai.codex.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "minimal";
        };
      in
        !(result.config.programs.git.settings ? branchless)
        && result.config.ai.codex.skills ? stack-fix
    );

    # Conversely, a runtime negation does not retract Git configuration selected
    # by the portable program enable.
    module-sws-runtime-negation-keeps-git-preset = mkTest "sws-runtime-negation-keeps-git-preset" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          ai.codex.programs.stacked-workflows.enable = false;
          stacked-workflows.gitPreset = "minimal";
        };
      in
        result.config.programs.git.settings ? branchless
        && !(result.config.ai.codex.skills ? stack-fix)
    );

    # Git config applies when preset is "minimal".
    module-sws-git-config-minimal = mkTest "sws-git-config-minimal" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "minimal";
        };
        gitSettings = result.config.programs.git.settings;
      in
        (gitSettings ? branchless)
        && (gitSettings ? pull)
        && (gitSettings ? rebase)
    );

    # Git config applies when preset is "full" (includes extended settings).
    module-sws-git-config-full = mkTest "sws-git-config-full" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "full";
        };
        gitSettings = result.config.programs.git.settings;
      in
        (gitSettings ? branchless)
        && (gitSettings ? diff)
        && (gitSettings ? fetch)
        && (gitSettings ? push)
        && (gitSettings ? revise)
    );

    # Git config NOT set when preset is "none".
    module-sws-git-config-none = mkTest "sws-git-config-none" (
      let
        result = evalHm {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "none";
        };
        gitSettings = result.config.programs.git.settings;
      in
        !(gitSettings ? branchless)
    );

    # Devenv renders the same minimal preset into a repository-local fragment
    # and orders both mutation tasks before the upstream hook installer.
    module-sws-devenv-git-config-minimal = mkTest "sws-devenv-git-config-minimal" (
      let
        result = evalDevenvModules [
          {
            options.git-hooks.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          }
          {
            config = {
              ai.programs.stacked-workflows.enable = true;
              git-hooks.enable = true;
              stacked-workflows.gitPreset = "minimal";
            };
          }
        ];
        includeTask = result.config.tasks."stacked-workflows:git-config";
        initTask = result.config.tasks."stacked-workflows:branchless-init";
      in
        result.config.files.${presetPath}.text
        == lib.generators.toGitINI sharedGitConfig.minimal
        && includeTask.after == ["devenv:files"]
        && includeTask.before == ["stacked-workflows:branchless-init"]
        && initTask.after == ["stacked-workflows:git-config"]
        && initTask.before == ["devenv:git-hooks:install"]
    );

    # Full uses the same shared data and includes its extended sections.
    module-sws-devenv-git-config-full = mkTest "sws-devenv-git-config-full" (
      let
        result = evalDevenv {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "full";
        };
      in
        result.config.files.${presetPath}.text
        == lib.generators.toGitINI sharedGitConfig.full
        && lib.hasInfix ''[branchless "test"]'' result.config.files.${presetPath}.text
        && result.config.tasks ? "stacked-workflows:branchless-init"
        && result.config.tasks ? "stacked-workflows:git-config"
    );

    # None keeps only the reconciliation task so it can remove stale state.
    module-sws-devenv-git-config-none = mkTest "sws-devenv-git-config-none" (
      let
        result = evalDevenv {
          ai.programs.stacked-workflows.enable = true;
          stacked-workflows.gitPreset = "none";
        };
      in
        !(result.config.files ? ${presetPath})
        && !(result.config.tasks ? "stacked-workflows:branchless-init")
        && result.config.tasks ? "stacked-workflows:git-config"
    );

    # The option alone cannot activate its side effects; the portable program
    # enable remains the owner of both the skills and Git companion.
    module-sws-devenv-git-preset-requires-portable-enable = mkTest "sws-devenv-git-preset-requires-portable-enable" (
      let
        result = evalDevenv {stacked-workflows.gitPreset = "minimal";};
      in
        !(result.config.files ? ${presetPath})
        && !(result.config.tasks ? "stacked-workflows:branchless-init")
        && result.config.tasks ? "stacked-workflows:git-config"
    );

    # The common-config include is stable across linked worktrees. Transitions
    # to either inactive state remove only the exact include this module owns.
    module-sws-devenv-git-config-reconciliation = let
      enabled = evalDevenv {
        ai.programs.stacked-workflows.enable = true;
        stacked-workflows.gitPreset = "minimal";
      };
      disabled = evalDevenv {stacked-workflows.gitPreset = "minimal";};
      none = evalDevenv {
        ai.programs.stacked-workflows.enable = true;
        stacked-workflows.gitPreset = "none";
      };
      enabledFragment = pkgs.writeText "stacked-workflows.gitconfig" enabled.config.files.${presetPath}.text;
    in
      pkgs.runCommand "module-sws-devenv-git-config-reconciliation" {} ''
        repository="$TMPDIR/repository"
        linked="$TMPDIR/linked"
        ${lib.getExe pkgs.git} init --initial-branch=main "$repository"
        ${lib.getExe pkgs.git} -C "$repository" config user.email test@example.invalid
        ${lib.getExe pkgs.git} -C "$repository" config user.name Test
        touch "$repository/tracked"
        ${lib.getExe pkgs.git} -C "$repository" add tracked
        ${lib.getExe pkgs.git} -C "$repository" commit -m initial
        ${lib.getExe pkgs.git} -C "$repository" worktree add "$linked" -b linked
        mkdir -p "$linked/.devenv"
        ln -s ${enabledFragment} "$linked/${presetPath}"

        repository_config="$repository/.git/config"
        preset_path="$repository/.git/stacked-workflows.gitconfig"
        unrelated="$TMPDIR/unrelated.gitconfig"
        printf '%s\n' '[test]' '  unrelated = true' >"$unrelated"
        ${lib.getExe pkgs.git} config --file "$repository_config" --add include.path "$unrelated"

        DEVENV_ROOT="$linked" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:git-config".exec}
        test "$(${lib.getExe pkgs.git} config --file "$repository_config" --fixed-value --get-all include.path "$preset_path")" = "$preset_path"
        test "$(${lib.getExe pkgs.git} -C "$linked" config --get branchless.core.mainBranch)" = main

        rm "$preset_path"
        DEVENV_ROOT="$linked" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg none.config.tasks."stacked-workflows:git-config".exec}
        ! ${lib.getExe pkgs.git} config --file "$repository_config" --fixed-value --get-all include.path "$preset_path"
        test "$(${lib.getExe pkgs.git} config --file "$repository_config" --fixed-value --get-all include.path "$unrelated")" = "$unrelated"
        test ! -e "$preset_path"

        DEVENV_ROOT="$linked" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:git-config".exec}
        DEVENV_ROOT="$linked" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg disabled.config.tasks."stacked-workflows:git-config".exec}
        ! ${lib.getExe pkgs.git} config --file "$repository_config" --fixed-value --get-all include.path "$preset_path"
        test "$(${lib.getExe pkgs.git} config --file "$repository_config" --fixed-value --get-all include.path "$unrelated")" = "$unrelated"
        touch "$out"
      '';

    # The common config and branchless state are shared by linked worktrees.
    # Repeated paired invocations must serialize both transactions: the include
    # and fragment agree after every enable/disable race, and two first-time
    # initializers both succeed.
    module-sws-devenv-common-state-concurrency = let
      enabled = evalDevenv {
        ai.programs.stacked-workflows.enable = true;
        stacked-workflows.gitPreset = "minimal";
      };
      none = evalDevenv {
        ai.programs.stacked-workflows.enable = true;
        stacked-workflows.gitPreset = "none";
      };
      enabledFragment = pkgs.writeText "stacked-workflows.gitconfig" enabled.config.files.${presetPath}.text;
    in
      pkgs.runCommand "module-sws-devenv-common-state-concurrency" {} ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        for iteration in $(${lib.getExe' pkgs.coreutils "seq"} 1 20); do
          repository="$TMPDIR/repository-$iteration"
          first="$TMPDIR/first-$iteration"
          second="$TMPDIR/second-$iteration"
          ${lib.getExe pkgs.git} init --initial-branch=main "$repository"
          ${lib.getExe pkgs.git} -C "$repository" config user.email test@example.invalid
          ${lib.getExe pkgs.git} -C "$repository" config user.name Test
          touch "$repository/tracked"
          ${lib.getExe pkgs.git} -C "$repository" add tracked
          ${lib.getExe pkgs.git} -C "$repository" commit -m initial
          ${lib.getExe pkgs.git} -C "$repository" worktree add "$first" -b first
          ${lib.getExe pkgs.git} -C "$repository" worktree add "$second" -b second
          mkdir -p "$first/.devenv" "$second/.devenv"
          ln -s ${enabledFragment} "$first/${presetPath}"
          ln -s ${enabledFragment} "$second/${presetPath}"

          DEVENV_ROOT="$first" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:git-config".exec} &
          enable_pid="$!"
          DEVENV_ROOT="$second" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg none.config.tasks."stacked-workflows:git-config".exec} &
          disable_pid="$!"
          wait "$enable_pid"
          wait "$disable_pid"

          repository_config="$repository/.git/config"
          preset_path="$repository/.git/stacked-workflows.gitconfig"
          include_present=false
          if ${lib.getExe pkgs.git} config --file "$repository_config" \
            --fixed-value --get-all include.path "$preset_path" >/dev/null; then
            include_present=true
          else
            include_status="$?"
            test "$include_status" -eq 1
          fi
          fragment_present=false
          if test -e "$preset_path"; then
            fragment_present=true
            test "$(${lib.getExe pkgs.git} config --file "$preset_path" branchless.core.mainBranch)" = main
          fi
          test "$include_present" = "$fragment_present"

          DEVENV_ROOT="$first" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:git-config".exec}
          DEVENV_ROOT="$first" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:branchless-init".exec} &
          first_pid="$!"
          DEVENV_ROOT="$second" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:branchless-init".exec} &
          second_pid="$!"
          wait "$first_pid"
          wait "$second_pid"
          test -d "$repository/.git/branchless"
        done

        DEVENV_ROOT="$first" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg enabled.config.tasks."stacked-workflows:git-config".exec}
        touch "$repository/.git/config.lock"
        if DEVENV_ROOT="$first" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg none.config.tasks."stacked-workflows:git-config".exec}; then
          echo "disabled reconciliation unexpectedly ignored config.lock" >&2
          exit 1
        fi
        test -e "$repository/.git/stacked-workflows.gitconfig"

        touch "$out"
      '';

    # Check the rendered task bodies as standalone Bash, which is how devenv
    # executes tasks. This catches strict-mode and quoting regressions early.
    module-sws-devenv-task-shellcheck = let
      result = evalDevenv {
        ai.programs.stacked-workflows.enable = true;
        stacked-workflows.gitPreset = "full";
      };
      includeScript = pkgs.writeText "stacked-workflows-git-config.sh" ''
        #!/usr/bin/env bash
        ${result.config.tasks."stacked-workflows:git-config".exec}
      '';
      initScript = pkgs.writeText "stacked-workflows-branchless-init.sh" ''
        #!/usr/bin/env bash
        ${result.config.tasks."stacked-workflows:branchless-init".exec}
      '';
    in
      pkgs.runCommand "module-sws-devenv-task-shellcheck" {} ''
        ${lib.getExe pkgs.shellcheck} ${includeScript}
        ${lib.getExe pkgs.shellcheck} ${initScript}
        touch "$out"
      '';

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
