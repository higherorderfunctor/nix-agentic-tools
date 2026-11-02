{
  # `{lib, extracted ? <the committed sidecar>}: {options; leaves; report;
  # revsetFunctions; assertions;}` — the shared generator
  # (lib/git-tool-settings) over git-branchless's sidecar, with the two hand
  # tables only this tool needs.
  git-branchless.settings = {
    lib,
    extracted ?
      import ../../../lib/git-tool-settings/extracted.nix {
        dir = ../extracted;
        inherit lib;
      },
  }: let
    generated = import ../../../lib/git-tool-settings {
      inherit extracted lib;
      rows = builtins.fromJSON (builtins.readFile ../extract/annotations.json);
      tool = "git-branchless";
      exclusions = {
        "branchless.mainBranch" = "the legacy name of `branchless.core.mainBranch`, which git-branchless reads first. `git branchless init` writes that key into every repository it initializes, so this one never takes effect there; set `branchless.core.mainBranch` instead";
      };
      refinements = {
        # A negative value is a runtime error, and git-branchless reads an i32.
        "branchless.test.jobs" = {
          type = "int";
          refine = _: lib.types.ints.between 0 2147483647;
        };
        # The builtin table is consulted before any alias, so an alias named
        # after a builtin is silently dead. The extractor fails (F14) if that
        # lookup order changes.
        "branchless.revsets.alias.<name>" = {
          type = "string";
          refine = {familyType, ...}:
            familyType {
              valueType = lib.types.str;
              nameCheck = name: !(lib.elem (lib.toLower name) extracted.revsetFunctions);
              nameRule = ", and none named after a builtin revset function";
            };
        };
      };
    };
  in
    generated
    // {
      # The test.jobs/test.strategy coupling, in two strengths. The tool
      # factory (lib/git-tool-settings/tool-module.nix) evaluates both lists
      # wherever the tree mounts, so a sandbox tree gets them too.
      # `assertions` holds what every scope knows: an explicit working-copy
      # strategy cannot run a jobs value above 1. `lowestScopeAssertions`
      # holds what only the lowest scopes know — that an UNSET strategy there
      # is upstream's working-copy; repository-local mounts pass none of it
      # (a user-global strategy may still supply the leaf, so devenv only
      # warns).
      # Parenthesized on purpose: a bare lambda is not a valid list element,
      # and the factory's `{cfg, optionPath}` argument arrives as one attrset.
      assertions = [
        (ctx: let
          test = ctx.cfg.settings.test;
        in {
          assertion = !(test.jobs != null && test.jobs != 1 && test.strategy == "working-copy");
          message = ''
            ${ctx.optionPath}.settings.test.jobs = ${toString test.jobs} contradicts ${ctx.optionPath}.settings.test.strategy = "working-copy".
            git-branchless runs one job at a time with the working-copy strategy, and a configured jobs value does not change the strategy, so every `git test run` would fail. Set test.strategy = "worktree".
          '';
        })
      ];
      # The same coupling where the tree writes git's LOWEST scope: Home
      # Manager's user-global file and the sandbox's guest system file. There
      # nothing below the written file can supply a strategy, so an unset one
      # IS upstream's default working-copy and a jobs value above 1 fails
      # every `git test run` — those mounts carry these through the factory's
      # `assertions` parameter, while repository-local mounts (devenv) only
      # warn, because a user-global strategy may still supply the leaf.
      lowestScopeAssertions = [
        (ctx: let
          test = ctx.cfg.settings.test;
        in {
          assertion = test.jobs == null || test.jobs == 1 || test.strategy == "worktree";
          message = ''
            ${ctx.optionPath}.settings.test.jobs = ${toString test.jobs} needs ${ctx.optionPath}.settings.test.strategy = "worktree".
            git-branchless runs one job at a time with the working-copy strategy (its default), and a configured jobs value does not change the strategy, so every `git test run` would fail.
          '';
        })
      ];
    };
}
