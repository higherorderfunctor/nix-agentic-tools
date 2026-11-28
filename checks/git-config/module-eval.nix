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
  inherit (harness) checkRows evalDevenv evalDevenvModules evalHm mkTest rejectsChange;

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
        checkRows "git option parity" {
          "Home Manager and devenv have the same option names and types" = hm == devenv;
          "git root contains all four sections" = lib.attrNames hm == ["absorb" "branchless" "revise" "settings"];
        }
    );

    # The Home Manager stub is Home Manager's real type: a four-level key and
    # a null are rejected, as Home Manager rejects them.
    module-git-hm-stub-is-the-real-type = mkTest "git-hm-stub-is-the-real-type" (
      let
        settings = input: (hmSettings {programs.git.settings.branchless = input;}).branchless or {};
        dotted = {"test.alias".foo = "x";};
      in
        checkRows "Home Manager Git INI type" {
          "null cannot be a Git INI value" = rejectsChange settings {
            valid = dotted;
            invalid = {"test.alias".foo = null;};
            expected = dotted;
          };
          "subsection cannot be nested four levels deep" = rejectsChange settings {
            valid = dotted;
            invalid = {test.alias.foo = "x";};
            expected = dotted;
          };
        }
    );

    # Check the option values before serialization: an unset scalar or empty
    # family must not inject settings next to the configured leaf.
    module-git-typed-null-not-rendered = mkTest "git-typed-null-not-rendered" (
      let
        one = {git.absorb.settings.maxStack = 7;};
        expected = {absorb.maxStack = 7;};
      in
        checkRows "omission of unset Git settings" {
          "Home Manager writes only absorb.maxStack when set" = hmSettings one == expected;
          "devenv writes only absorb.maxStack when set" = devenvSettings one == expected;
        }
    );

    # A `<name>` family lowers to the dotted subsection, the only shape Home
    # Manager's type admits.
    module-git-typed-renders-dotted-subsection = mkTest "git-typed-renders-dotted-subsection" (
      let
        config = {git.branchless.settings.test.alias.lint = "nix flake check";};
        expected = {branchless."test.alias".lint = "nix flake check";};
      in
        checkRows "branchless test alias subsection" {
          "Home Manager keeps test.alias as a single subsection" = hmSettings config == expected;
        }
    );

    # Priorities survive lowering. A typed value set with mkDefault (what a
    # preset does) yields to a raw value; an explicit typed value that
    # disagrees with a raw one is a conflict; agreeing values merge. Both
    # backends: the raw attrset is `programs.git.settings` or `git.settings`.
    module-git-typed-priority = mkTest "git-typed-priority" (
      let
        read = settings: raw: {
          typed,
          value,
        }:
          (settings (lib.recursiveUpdate {git.absorb.settings.maxStack = typed;} (raw value))).absorb.maxStack or null;
        hm = read hmSettings (value: {programs.git.settings.absorb.maxStack = value;});
        devenv = read devenvSettings (value: {git.settings.absorb.maxStack = value;});
        conflict = get:
          rejectsChange get {
            valid = {
              typed = 5;
              value = 5;
            };
            invalid = {
              typed = 5;
              value = 9;
            };
            expected = 5;
          };
        overridesDefault = get:
          get {
            typed = lib.mkDefault 5;
            value = 9;
          }
          == 9;
      in
        checkRows "typed Git setting priorities" {
          "Home Manager rejects conflicting explicit values" = conflict hm;
          "Home Manager retains mkForce on typed value" =
            hm {
              typed = lib.mkForce 3;
              value = 9;
            }
            == 3;
          "Home Manager uses raw value over typed default" = overridesDefault hm;
          "devenv rejects conflicting explicit values" = conflict devenv;
          "devenv uses raw value over typed default" = overridesDefault devenv;
        }
    );

    # Home Manager renders nothing while programs.git.enable is false, so
    # defining `git.*` then warns instead of doing nothing silently.
    module-git-hm-warns-without-programs-git = mkTest "git-hm-warns-without-programs-git" (
      let
        warns = config:
          lib.any (lib.hasInfix "programs.git.enable is false, so Home Manager writes no git configuration")
          (evalHm config).config.warnings;
        typed = {git.absorb.settings.maxStack = 3;};
      in
        checkRows "Home Manager Git delivery warning" {
          "empty settings do not warn" = !(warns {});
          "enabled Git delivers typed settings without warning" = !(warns (typed // {programs.git.enable = true;}));
          "raw git.settings warns when Git is disabled" = warns {git.settings.merge.conflictStyle = "zdiff3";};
          # A raw programs.git.settings value is Home Manager's own business.
          "raw programs.git.settings is outside the warning's scope" = !(warns {programs.git.settings.merge.conflictStyle = "zdiff3";});
          "scopedSync warns when its alias would not be delivered" = warns {git.branchless.scopedSync = true;};
          "typed absorb settings warn when Git is disabled" = warns typed;
        }
    );

    # Ranges from the census: git-branchless reads test.jobs as a
    # non-negative i32; git-absorb's maxStack is at least 1.
    module-git-int-ranges = mkTest "git-int-ranges" (
      let
        jobs = value:
          (hmSettings {
            git.branchless.settings.test = {
              jobs = value;
              strategy = "worktree";
            };
          }).branchless.test.jobs or null;
        maxStack = value: (hmSettings {git.absorb.settings.maxStack = value;}).absorb.maxStack or null;
      in
        checkRows "typed Git integer bounds" {
          "absorb maxStack must be at least one" = rejectsChange maxStack {
            valid = 1;
            invalid = 0;
            expected = 1;
          };
          "absorb maxStack must fit in an i32" = rejectsChange maxStack {
            valid = 2147483647;
            invalid = 2147483648;
            expected = 2147483647;
          };
          "branchless jobs must fit in an i32" = rejectsChange jobs {
            valid = 2147483647;
            invalid = 2147483648;
            expected = 2147483647;
          };
        }
    );

    # Family names are plain (a dotted name would fold its head into a
    # case-sensitive subsection), and a revset alias named after a builtin
    # revset function — which git-branchless consults first — is rejected,
    # case-insensitively.
    module-git-alias-names = mkTest "git-alias-names" (
      let
        testAlias = name: (hmSettings {git.branchless.settings.test.alias.${name} = "true";}).branchless."test.alias" or {};
        revsetAlias = name: (hmSettings {git.branchless.settings.revsets.alias.${name} = "@";}).branchless."revsets.alias" or {};
        rejectsTestAlias = invalid:
          rejectsChange testAlias {
            inherit invalid;
            valid = "lint-all";
            expected.lint-all = "true";
          };
        rejectsRevsetAlias = invalid:
          rejectsChange revsetAlias {
            inherit invalid;
            valid = "mine";
            expected.mine = "@";
          };
      in
        checkRows "branchless alias names" {
          "revset builtin names are reserved case-insensitively" = rejectsRevsetAlias "Stack";
          "test alias must start with a letter" = rejectsTestAlias "1st";
        }
    );

    # A configured test.jobs other than 1 needs the worktree strategy. Home
    # Manager is the lowest layer, so a null strategy there is upstream's
    # working-copy and fails. Repository-local, a null strategy may come from
    # user-global, so it only warns; an explicit working-copy fails.
    module-git-branchless-test-jobs-coupling = mkTest "git-branchless-test-jobs-coupling" (
      let
        test = settings: {git.branchless.settings.test = settings;};
        hm = settings: failedAssertions (evalHm (test settings));
        devenv = settings: evalDevenv (test settings);
        repoFails = settings: failedAssertions (devenv settings);
        repoWarns = settings: lib.any (lib.hasInfix "test.strategy unset") (devenv settings).config.warnings;
        reports = reason: lib.any (lib.hasInfix reason);
      in
        checkRows "branchless test jobs and strategy" {
          "Home Manager accepts one job with implicit strategy" = hm {jobs = 1;} == [];
          "Home Manager accepts parallel jobs with worktree strategy" =
            hm {
              jobs = 4;
              strategy = "worktree";
            }
            == [];
          "Home Manager rejects two jobs with implicit working-copy strategy" =
            reports ''test.jobs = 2 needs git.branchless.settings.test.strategy = "worktree"'' (hm {jobs = 2;});
          "Home Manager rejects zero jobs with explicit working-copy strategy" = reports ''test.jobs = 0 needs git.branchless.settings.test.strategy = "worktree"'' (hm {
            jobs = 0;
            strategy = "working-copy";
          });
          "devenv accepts but warns about parallel jobs with implicit strategy" =
            repoFails {jobs = 2;} == [] && repoWarns {jobs = 2;};
          "devenv does not warn for one job with implicit strategy" = !(repoWarns {jobs = 1;});
          "devenv does not warn for parallel jobs with worktree strategy" =
            !(repoWarns {
              jobs = 2;
              strategy = "worktree";
            });
          "devenv rejects parallel jobs with explicit working-copy strategy" =
            reports ''test.jobs = 2 contradicts git.branchless.settings.test.strategy = "working-copy"''
            (repoFails {
              jobs = 2;
              strategy = "working-copy";
            });
        }
    );

    # The shared setting must reject a non-string revset and lower a valid
    # revset to the patched restack key, not to a Git alias.
    module-git-branchless-restack-default-revset = mkTest "git-branchless-restack-default-revset" (
      checkRows "branchless restack default revset" {
        "Home Manager rejects a boolean in place of a revset" = rejectsChange (revset: hmSettings {git.branchless.settings.restack.defaultRevset = revset;}) {
          valid = "@";
          invalid = false;
          expected.branchless.restack.defaultRevset = "@";
        };
      }
    );

    # A raw alias must override the preset on either backend.
    module-git-branchless-scoped-sync = mkTest "git-branchless-scoped-sync" (
      let
        preset = {git.branchless.scopedSync = lib.mkDefault true;};
      in
        checkRows "scoped sync alias" {
          "Home Manager lets a raw alias override the preset" =
            (hmSettings (preset // {programs.git.settings.alias.sync = "branchless sync";})).alias.sync == "branchless sync";
          "devenv lets a raw alias override the preset" =
            (devenvSettings (lib.recursiveUpdate preset {git.settings.alias.sync = "branchless sync";})).alias.sync == "branchless sync";
        }
    );

    # Each enable switch must select this flake's build of its own tool.
    module-git-tools-enable-installs = mkTest "git-tools-enable-installs" (
      let
        tools = {
          absorb = pkgs.ai.gitTools.git-absorb;
          branchless = pkgs.ai.gitTools.git-branchless;
          revise = pkgs.ai.gitTools.git-revise;
        };
        installed = backend: packages: let
          owns = package: lib.any (installedPackage: installedPackage.drvPath == package.drvPath);
          disabled = packages {};
        in
          lib.mapAttrs' (tool: package:
            lib.nameValuePair "${backend} installs git-${tool} only when git.${tool}.enable is set" (
              let
                enabled = packages {git.${tool}.enable = true;};
              in
                owns package enabled && !(owns package disabled)
            ))
          tools;
      in
        checkRows "Git tool installation" (
          installed "Home Manager" (config: (evalHm config).config.home.packages)
          // installed "devenv" (config: (evalDevenv config).config.packages)
        )
    );

    # The runtime check runs the tasks in a fixed order. Independently pin the
    # actual graph: init must precede config publication and hook installation.
    module-git-devenv-tasks = mkTest "git-devenv-tasks" (
      let
        tasksFor = gitHooks:
          (evalDevenvModules [
            {
              options.git-hooks.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
            }
            {
              config = {
                git-hooks.enable = gitHooks;
                git.branchless.enable = true;
              };
            }
          ]).config.tasks;
        withHooks = tasksFor true;
        withoutHooks = tasksFor false;
        initBefore = tasks: lib.sort lib.lessThan tasks."ai:git-branchless-init".before;
      in
        checkRows "Git devenv task graph" {
          "branchless init does not require a disabled hook installer" =
            initBefore withoutHooks == ["devenv:enterShell" "git:config"];
          "branchless init is absent when branchless is disabled" = !((evalDevenv {}).config.tasks ? "ai:git-branchless-init");
          "branchless init precedes config and the enabled hook installer" =
            initBefore withHooks == ["devenv:enterShell" "devenv:git-hooks:install" "git:config"];
          "config publication precedes shell entry" = withHooks."git:config".before == ["devenv:enterShell"];
        }
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
        ${lib.getExe pkgs.shellcheck} ${script "ai:git-branchless-init"} ${script "git:config"}
        touch "$out"
      '';
  };
}
