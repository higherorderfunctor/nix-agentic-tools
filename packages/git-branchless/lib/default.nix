{
  # `{lib, extracted ? <the committed sidecar>}: {options; leaves; report; revsetFunctions;}`
  # — the shared generator (lib/git-tool-settings) over git-branchless's
  # sidecar, with the two hand tables only this tool needs.
  git-branchless.settings = {
    lib,
    extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  }:
    import ../../../lib/git-tool-settings {
      inherit extracted lib;
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
}
