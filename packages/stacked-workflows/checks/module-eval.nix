# cspell:ignore autoStash zdiff
# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm harnessNames mkTest;
  optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib;};
  pool = result: runtime: surface: lib.attrByPath (optionPaths.pool runtime surface) {} result.config;
  enabled.ai.programs.stacked-workflows.enable = true;
  skills = ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"];
  rules = ["stacked-workflows-router"];
  members = names: attrs: lib.filter (name: attrs ? ${name}) names;
  presetConfig = preset: enabled // {stacked-workflows.gitPreset = preset;};
  backends = {
    devenv = {
      evaluate = evalDevenv;
      gitSettings = result: result.config.git.settings;
      pullFf.git.settings.pull.ff = "only";
    };
    hm = {
      evaluate = evalHm;
      gitSettings = result: result.config.programs.git.settings;
      pullFf.programs.git.settings.pull.ff = "only";
    };
  };
  backendRows = label: rows: checkRows label (lib.mapAttrs (_: rows) backends);
  assertionsPass = result: lib.all (entry: entry.assertion) result.config.assertions;
  hasPullFfConflict = result:
    lib.any (entry:
      !entry.assertion
      && lib.hasInfix "git.settings.pull.ff" entry.message
      && lib.hasInfix "conflicts with stacked-workflows.gitPreset" entry.message)
    result.config.assertions;

  # Fixed answers from the approved presets, not imports of the production
  # settings. Retain the entire key set: a stray fetch.pruneTags or a pinned
  # branchless.core.mainBranch is just as much a regression as a lost key.
  commonGitSettings = {
    absorb = {
      fixupTargetAlwaysSHA = true;
      maxStack = 50;
      oneFixupPerCommit = true;
    };
    init.defaultBranch = "main";
    merge.conflictStyle = "zdiff3";
    pull.rebase = true;
    rebase = {
      autoSquash = true;
      autoStash = true;
      updateRefs = true;
    };
    rerere = {
      autoupdate = true;
      enabled = true;
    };
  };
  expectedGitSettings = {
    full =
      commonGitSettings
      // {
        alias.sync = "branchless sync 'stack()'";
        branchless = {
          navigation.autoSwitchBranches = true;
          next.interactive = true;
          restack = {
            defaultRevset = "descendants(roots((stack() & ::HEAD) - ::origin/main)) - ::origin/main";
            preserveTimestamps = true;
          };
          smartlog.defaultRevset = "(@ % main()) | stack() | descendants(@) | @";
          test = {
            jobs = 1;
            strategy = "worktree";
          };
        };
        commit.verbose = true;
        diff = {
          algorithm = "histogram";
          colorMoved = "plain";
          mnemonicPrefix = true;
        };
        fetch = {
          all = true;
          prune = true;
        };
        push = {
          autoSetupRemote = true;
          followTags = true;
        };
        revise.autoSquash = true;
        tag.sort = "version:refname";
      };
    minimal = commonGitSettings;
    none = {};
  };
in {
  checks = {
    module-sws-default-disabled = mkTest "sws-default-disabled" (
      let
        result = evalHm {};
      in
        checkRows "default program" {
          "legacy enable option is not reintroduced" = !(result.options.stacked-workflows ? enable);
          "portable enable stays opt-in" = !result.config.ai.programs.stacked-workflows.enable;
        }
    );

    # Module provenance separately guards root writes that would fan out beyond
    # package ownership. Use the registry to include newly added runtimes here,
    # with Claude pinned as a positive control.
    module-sws-runtime-pools = mkTest "sws-runtime-pools" (
      lib.all (backend: let
        result = backends.${backend}.evaluate enabled;
        surfaceCheck = surface: names: let
          supports = runtime: builtins.elem backend (optionPaths.records.${runtime}.surfaceSupport.${surface}.backends or []);
          actual = runtime: members names (pool result runtime surface);
        in
          checkRows "${backend} ${surface} ownership" ({
              "Claude still receives the complete contribution" = actual "claude" == names;
            }
            // lib.genAttrs (lib.remove "claude" harnessNames) (runtime:
              if supports runtime
              then actual runtime == names
              else pool result runtime surface == {}));
      in
        surfaceCheck "rules" rules && surfaceCheck "skills" skills)
      (lib.attrNames backends)
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
        && !(devenv.config.tasks ? "ai:git-branchless-init")
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

    # Both backends must lower the exact fixed settings for each preset. A
    # shared rendering bug could otherwise leave backend parity intact.
    module-sws-presets-expected-settings = mkTest "sws-presets-expected-settings" (
      backendRows "preset settings" ({
        evaluate,
        gitSettings,
        ...
      }:
        checkRows "selected preset" {
          "full retains recommended settings without pruning backup tags" = gitSettings (evaluate (presetConfig "full")) == expectedGitSettings.full;
          "minimal does not pick up full-only settings" = gitSettings (evaluate (presetConfig "minimal")) == expectedGitSettings.minimal;
          "none does not write any settings" = gitSettings (evaluate (presetConfig "none")) == expectedGitSettings.none;
        })
    );

    # Preset values must reach typed options at default priority; identical raw
    # Git output is not sufficient. The public key set above pins the leaves
    # without importing the very preset declarations being checked.
    module-sws-preset-leaves-are-options = mkTest "sws-preset-leaves-are-options" (
      let
        evaluated = evalHm (presetConfig "full");
        tools = ["absorb" "branchless" "revise"];
        typedDefault = option: option != null && lib.isOption option && option.highestPrio == 1000;
        sections = builtins.intersectAttrs (lib.genAttrs tools (_: null)) expectedGitSettings.full;
        leaves = lib.concatLists (lib.mapAttrsToList (section: settings:
          lib.collect lib.isList (lib.mapAttrsRecursive (path: _: [section] ++ path) settings))
        sections);
        leafRows = lib.listToAttrs (map (path: let
            section = builtins.head path;
            field = builtins.tail path;
          in {
            name = "${lib.concatStringsSep "." path} stays a typed default";
            value = typedDefault (lib.attrByPath ([section "settings"] ++ field) null evaluated.options.git);
          })
          leaves);
        toolRows = lib.listToAttrs (map (tool: {
            name = "${tool} is enabled without forcing it on";
            value = evaluated.config.git.${tool}.enable && typedDefault evaluated.options.git.${tool}.enable;
          })
          tools);
      in
        checkRows "preset defaults" (leafRows
          // toolRows
          // {
            "scoped sync is set without forcing it on" = evaluated.config.git.branchless.scopedSync && typedDefault evaluated.options.git.branchless.scopedSync;
          })
    );

    # The assertion is shared, but each backend reads the setting at a
    # different input path. Failure must be the preset conflict, not any assertion.
    module-sws-pull-ff-assertion = mkTest "sws-pull-ff-assertion" (
      backendRows "pull.ff conflicts" ({
        evaluate,
        pullFf,
        ...
      }:
        checkRows "pull.ff restrictions" {
          "full rejects fast-forward-only pulling" = hasPullFfConflict (evaluate (presetConfig "full" // pullFf));
          "minimal accepts an omitted pull.ff" = assertionsPass (evaluate (presetConfig "minimal"));
          "minimal rejects fast-forward-only pulling" = hasPullFfConflict (evaluate (presetConfig "minimal" // pullFf));
          "none accepts fast-forward-only pulling" = assertionsPass (evaluate (presetConfig "none" // pullFf));
        })
    );

    # devenv: an active preset enables git.branchless and its init task;
    # "none" does not initialize branchless even when the program is enabled.
    module-sws-devenv-preset-tasks = mkTest "sws-devenv-preset-tasks" (
      let
        tasksOf = config: (evalDevenv config).config.tasks;
      in
        checkRows "devenv tasks" {
          "minimal initializes branchless" = tasksOf (presetConfig "minimal") ? "ai:git-branchless-init";
          "none does not initialize branchless" = !(tasksOf (presetConfig "none") ? "ai:git-branchless-init");
        }
    );

    # The documented restack Gitconfig value must match the preset consumed by
    # Home Manager and devenv; unrelated defaultRevset examples do not satisfy it.
    module-sws-restack-default-doc-matches-preset = mkTest "sws-restack-default-doc-matches-preset" (
      let
        documented = builtins.readFile ../references/recommended-config.md;
        preset = (import ../lib/git-config-full.nix).branchless.restack.defaultRevset;
        restack = builtins.head (lib.splitString "\n[" (builtins.elemAt sections 1));
        sections = lib.splitString "[branchless \"restack\"]\n" documented;
        values = lib.filter (lib.hasPrefix "  defaultRevset = ") (lib.splitString "\n" restack);
      in
        builtins.length sections
        == 2
        && values == ["  defaultRevset = \"${preset}\""]
    );

    # References are bundled as REAL files inside each skill dir (deref'd at
    # build) — NOT written as separate .claude/references/* files anymore.
    # This guards the dangling-symlink regression: the skill's references must
    # resolve to real, present files.
    module-sws-skill-references-resolve = mkTest "sws-skill-references-resolve" (
      let
        result = evalDevenv enabled;
        skillPath = result.config.ai.claude.skills.stack-fix;
      in
        builtins.pathExists "${skillPath}/SKILL.md"
        && builtins.pathExists "${skillPath}/references/git-absorb.md"
        && builtins.pathExists "${skillPath}/references/git-branchless.md"
    );
  };
}
