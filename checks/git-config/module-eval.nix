# Evaluation contracts of the `git.*` option root, which four owners declare
# together: packages/git (`git.settings` and its delivery) and the git tool
# owners (`git.branchless`, `git.absorb`, `git.revise`, through
# lib/git-tool-settings/tool-module.nix). ./runtime.nix covers what the
# rendered configuration does in a real repository.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalDevenvModules evalHm mkTest;

  # A literal search over strings that carry store paths (a regex could
  # not take them).
  contains = needle: hay: harness.hasLiteral (builtins.unsafeDiscardStringContext needle) (builtins.unsafeDiscardStringContext hay);
  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  hmSettings = config: (evalHm config).config.programs.git.settings;
  devenvSettings = config: (evalDevenv config).config.git.settings;
  failedAssertions = evaluated: map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions);

  # The option tree below `git`, as nested names with each leaf's type
  # description. devenv's own `git.root` is not ours and has no Home Manager
  # counterpart.
  shape = opts:
    lib.mapAttrs (_: opt:
      if lib.isOption opt
      then opt.type.description
      else shape opt)
    (removeAttrs opts ["_module" "root"]);
in {
  checks = {
    # Both backends declare the same `git.*` tree with the same types — one
    # declaration per tool shared by both, and Home Manager's `git.settings`
    # alias taking the type devenv's `git.settings` declares.
    module-git-hm-devenv-option-parity = mkTest "git-hm-devenv-option-parity" (
      let
        hm = shape (evalHm {}).options.git;
        devenv = shape (evalDevenv {}).options.git;
      in
        hm
        == devenv
        && lib.attrNames hm == ["absorb" "branchless" "revise" "settings"]
        && hm.branchless ? scopedSync
        && hm.branchless.settings.test.jobs == devenv.branchless.settings.test.jobs
    );

    # The Home Manager stub is Home Manager's real type: a four-level key and
    # a null are rejected, as Home Manager rejects them.
    module-git-hm-stub-is-the-real-type = mkTest "git-hm-stub-is-the-real-type" (
      !(evaluates (hmSettings {programs.git.settings.branchless.test.alias.foo = "x";}))
      && !(evaluates (hmSettings {programs.git.settings.branchless.test.jobs = null;}))
      && evaluates (hmSettings {programs.git.settings.branchless."test.alias".foo = "x";})
    );

    # Nothing set: nothing rendered on either backend, and the devenv task
    # removes the include instead of writing an empty file. One typed value:
    # exactly that key, and no `null` anywhere.
    module-git-typed-null-not-rendered = mkTest "git-typed-null-not-rendered" (
      let
        one = {git.absorb.settings.maxStack = 7;};
        emptyDevenv = evalDevenv {};
      in
        hmSettings {}
        == {}
        && devenvSettings {} == {}
        && !(contains "nix-agentic-tools.gitconfig" emptyDevenv.config.tasks."git:config".exec)
        && hmSettings one == {absorb.maxStack = 7;}
        && devenvSettings one == {absorb.maxStack = 7;}
        && !(lib.hasInfix "null" (lib.generators.toGitINI (devenvSettings one)))
    );

    # A `<name>` family lowers to the dotted subsection, the only shape Home
    # Manager's type admits.
    module-git-typed-renders-dotted-subsection = mkTest "git-typed-renders-dotted-subsection" (
      let
        config = {git.branchless.settings.test.alias.lint = "nix flake check";};
        expected = {branchless."test.alias".lint = "nix flake check";};
      in
        hmSettings config
        == expected
        && devenvSettings config == expected
        && contains ''[branchless "test.alias"]'' (lib.generators.toGitINI (devenvSettings config))
    );

    # Priorities survive lowering. A typed value set with mkDefault (what a
    # preset does) yields to a raw value; an explicit typed value that
    # disagrees with a raw one is a conflict; agreeing values merge. Both
    # backends: the raw attrset is `programs.git.settings` or `git.settings`.
    module-git-typed-priority = mkTest "git-typed-priority" (
      let
        defaulted = {git.absorb.settings.maxStack = lib.mkDefault 5;};
        explicit = {git.absorb.settings.maxStack = 5;};
        hmRaw = value: {programs.git.settings.absorb.maxStack = value;};
        devenvRaw = value: {git.settings.absorb.maxStack = value;};
      in
        (hmSettings (lib.recursiveUpdate defaulted (hmRaw 9))).absorb.maxStack
        == 9
        && (devenvSettings (lib.recursiveUpdate defaulted (devenvRaw 9))).absorb.maxStack == 9
        && !(evaluates (hmSettings (lib.recursiveUpdate explicit (hmRaw 9))))
        && !(evaluates (devenvSettings (lib.recursiveUpdate explicit (devenvRaw 9))))
        && (hmSettings (lib.recursiveUpdate explicit (hmRaw 5))).absorb.maxStack == 5
        # mkForce on the typed value beats a normal raw value.
        && (hmSettings (lib.recursiveUpdate {git.absorb.settings.maxStack = lib.mkForce 3;} (hmRaw 9))).absorb.maxStack == 3
    );

    # Home Manager renders nothing while programs.git.enable is false, so
    # defining `git.*` then warns instead of doing nothing silently.
    module-git-hm-warns-without-programs-git = mkTest "git-hm-warns-without-programs-git" (
      let
        warns = config: lib.any (lib.hasPrefix "git.* settings") (evalHm config).config.warnings;
      in
        warns {git.absorb.settings.maxStack = 3;}
        && warns {git.settings.merge.conflictStyle = "zdiff3";}
        && warns {git.branchless.scopedSync = true;}
        && !(warns {
          git.absorb.settings.maxStack = 3;
          programs.git.enable = true;
        })
        && !(warns {})
        # A raw programs.git.settings value is Home Manager's own business.
        && !(warns {programs.git.settings.merge.conflictStyle = "zdiff3";})
    );

    # Ranges from the census: git-branchless reads test.jobs as a
    # non-negative i32; git-absorb's maxStack is at least 1.
    module-git-int-ranges = mkTest "git-int-ranges" (
      let
        jobs = value:
          evaluates (hmSettings {
            git.branchless.settings.test = {
              jobs = value;
              strategy = "worktree";
            };
          });
        maxStack = value: evaluates (hmSettings {git.absorb.settings.maxStack = value;});
      in
        !(jobs (-1))
        && jobs 0
        && jobs 2147483647
        && !(jobs 2147483648)
        && !(maxStack 0)
        && maxStack 1
        && !(maxStack 2147483648)
    );

    # Family names are plain (a dotted name would fold its head into a
    # case-sensitive subsection), and a revset alias named after a builtin
    # revset function — which git-branchless consults first — is rejected,
    # case-insensitively.
    module-git-alias-names = mkTest "git-alias-names" (
      let
        testAlias = name: evaluates (hmSettings {git.branchless.settings.test.alias.${name} = "true";});
        revsetAlias = name: evaluates (hmSettings {git.branchless.settings.revsets.alias.${name} = "@";});
      in
        testAlias "lint-all"
        && !(testAlias "a.b")
        && !(testAlias "1st")
        && !(testAlias "has_underscore")
        && revsetAlias "mine"
        && !(revsetAlias "draft")
        && !(revsetAlias "Stack")
    );

    # test.jobs above 1 needs the worktree strategy. Home Manager is the
    # lowest layer, so a null strategy there is upstream's working-copy and
    # fails; repository-local, a null strategy may come user-global, so it
    # only warns, and only an explicit working-copy fails.
    module-git-branchless-test-jobs-coupling = mkTest "git-branchless-test-jobs-coupling" (
      let
        test = settings: {git.branchless.settings.test = settings;};
        hmFails = settings: failedAssertions (evalHm (test settings)) != [];
        devenv = settings: evalDevenv (test settings);
        devenvFails = settings: failedAssertions (devenv settings) != [];
        devenvWarns = settings: lib.any (lib.hasInfix "test.strategy unset") (devenv settings).config.warnings;
      in
        hmFails {jobs = 2;}
        && hmFails {
          jobs = 0;
          strategy = "working-copy";
        }
        && !(hmFails {jobs = 1;})
        && !(hmFails {
          jobs = 4;
          strategy = "worktree";
        })
        && devenvFails {
          jobs = 2;
          strategy = "working-copy";
        }
        && !(devenvFails {jobs = 2;})
        && devenvWarns {jobs = 2;}
        && !(devenvWarns {jobs = 1;})
        && !(devenvWarns {
          jobs = 2;
          strategy = "worktree";
        })
    );

    # scopedSync lowers to git's alias.sync on both backends, at the priority
    # it is defined at.
    module-git-branchless-scoped-sync = mkTest "git-branchless-scoped-sync" (
      let
        alias = "branchless sync 'stack()'";
      in
        !(hmSettings {} ? alias)
        && (hmSettings {git.branchless.scopedSync = true;}).alias.sync == alias
        && (devenvSettings {git.branchless.scopedSync = true;}).alias.sync == alias
        && (hmSettings {
          git.branchless.scopedSync = lib.mkDefault true;
          programs.git.settings.alias.sync = "branchless sync";
        }).alias.sync
        == "branchless sync"
    );

    # `enable` installs the tool on each backend.
    module-git-tools-enable-installs = mkTest "git-tools-enable-installs" (
      let
        tools = ["absorb" "branchless" "revise"];
        enabled = lib.genAttrs tools (_: {enable = true;});
        names = packages: map lib.getName packages;
        expected = map lib.getName [pkgs.ai.gitTools.git-absorb pkgs.ai.gitTools.git-branchless pkgs.ai.gitTools.git-revise];
        hmPackages = names (evalHm {git = enabled;}).config.home.packages;
        devenvPackages = names (evalDevenv {git = enabled;}).config.packages;
      in
        lib.all (name: lib.elem name hmPackages && lib.elem name devenvPackages) expected
        && !(lib.elem (lib.getName pkgs.ai.gitTools.git-absorb) (names (evalHm {}).config.home.packages))
    );

    # devenv task graph: init runs before `git:config` (whose include must end
    # up after the one init appends) and before prek's hook installation; it
    # passes a typed main branch; `git:config` renders `git.settings` through
    # toGitINI into the file it includes.
    module-git-devenv-tasks = mkTest "git-devenv-tasks" (
      let
        evaluated = evalDevenvModules [
          {
            options.git-hooks.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          }
          {
            config = {
              git-hooks.enable = true;
              git.branchless = {
                enable = true;
                settings.core.mainBranch = "trunk";
              };
            };
          }
        ];
        inherit (evaluated.config) tasks;
        init = tasks."git:branchless-init";
        rendered = pkgs.writeText "nix-agentic-tools.gitconfig" (lib.generators.toGitINI evaluated.config.git.settings);
      in
        lib.sort lib.lessThan init.before
        == ["devenv:enterShell" "devenv:git-hooks:install" "git:config"]
        && tasks."git:config".before == ["devenv:enterShell"]
        && contains "init \"$DEVENV_ROOT\" ${lib.getExe pkgs.ai.gitTools.git-branchless} trunk" init.exec
        && contains "include \"$DEVENV_ROOT\" ${rendered}" tasks."git:config".exec
        && !((evalDevenv {}).config.tasks ? "git:branchless-init")
    );

    # The task bodies are standalone Bash, which is how devenv runs them.
    module-git-devenv-task-shellcheck = let
      evaluated = evalDevenv {
        git = {
          branchless.enable = true;
          settings.merge.conflictStyle = "zdiff3";
        };
      };
      script = name:
        pkgs.writeText "${lib.replaceStrings [":"] ["-"] name}.sh" ''
          #!/usr/bin/env bash
          ${evaluated.config.tasks.${name}.exec}
        '';
    in
      pkgs.runCommand "module-git-devenv-task-shellcheck" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe pkgs.shellcheck} ${script "git:branchless-init"} ${script "git:config"}
        touch "$out"
      '';
  };
}
