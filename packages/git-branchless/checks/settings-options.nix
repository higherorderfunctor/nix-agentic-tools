# The real sidecar pins the shipped surface; changed fixture sidecars expose
# a stale, hand-copied generator that happens to agree with today's sidecar.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;
  committed = import ../../../lib/git-tool-settings/extracted.nix {
    dir = ../extracted;
    inherit lib;
  };
  surfaceFor = extracted: (import ../lib/default.nix).git-branchless.settings {inherit extracted lib;};
  real = surfaceFor committed;
  withSetting = key: node: surfaceFor (lib.recursiveUpdate committed {settings.${key} = node;});
  without = key: surfaceFor (committed // {settings = builtins.removeAttrs committed.settings [key];});
  read = {reads."probe.rs#get_probe" = ["repository"];};

  added = withSetting "branchless.probe.added" (read // {type = "bool";});
  emptyEnum = withSetting "branchless.probe.enum" (read
    // {
      type = "enum";
      values = [];
    });
  nested = withSetting "branchless.test" (read // {type = "string";});
  newBuiltin = surfaceFor (committed // {revsetFunctions = committed.revsetFunctions ++ ["mine"];});
  unmapped = withSetting "branchless.probe.odd" (read // {type = "u64";});
  widened = withSetting "branchless.test.strategy" {
    values = committed.settings."branchless.test.strategy".values ++ [{value = "probe";}];
  };
  writeOnly = withSetting "branchless.probe.written" {
    reads = {};
    type = "string";
    writes."probe.rs#set_probe" = ["file"];
  };

  # Force the closed submodule's exact merge leaf. Reading the option tree
  # alone would not force the rejection of a consumer's value or unknown key.
  merged = surface: value:
    (lib.evalModules {
      modules = [
        {
          options.settings = lib.mkOption {
            type = lib.types.submodule {inherit (surface) options;};
            default = {};
          };
        }
        {config.settings = value;}
      ];
    }).config.settings;
  settingAt = surface: path: value:
    lib.attrByPath path null (merged surface (lib.setAttrByPath path value));
  pathFor = key: lib.splitString "." (lib.removeSuffix ".<name>" key);
  optionAt = surface: key: lib.attrByPath (pathFor key) null surface.options;
  unset = merged real {};
  familyKeys = ["branchless.revsets.alias.<name>" "branchless.test.alias.<name>"];
  strategy = settingAt real ["branchless" "test" "strategy"];
  testAlias = settingAt real ["branchless" "test" "alias"];
  rejectsTestAlias = name:
    rejectsChange testAlias {
      valid.ci-full = "true";
      invalid.${name} = "true";
      expected.ci-full = "true";
    };
  legacy = "branchless.mainBranch";
  # The pinned census has reads for every owned key; the one legacy name is
  # deliberately hidden. Do not let the generator's exclusion report decide
  # which keys this check requires: that would hide an accidental exclusion.
  shippedKeys = builtins.filter (key: key != legacy) (builtins.attrNames committed.settings);
in {
  checks.git-branchless-settings-options = mkTest "git-branchless-settings-options" (
    checkRows "branchless option surface" {
      "a new sidecar key is accepted only after it is added" = rejectsChange (surface:
        settingAt surface ["branchless" "probe" "added"] true) {
        valid = added;
        invalid = real;
        expected = true;
      };
      "a removed sidecar key becomes unknown to an existing consumer" = rejectsChange (surface:
        settingAt surface ["branchless" "smartlog" "reverse"] true) {
        valid = real;
        invalid = without "branchless.smartlog.reverse";
        expected = true;
      };
      "enum merge rejects a value absent from the sidecar" = rejectsChange strategy {
        valid = "worktree";
        invalid = "probe";
        expected = "worktree";
      };
      "legacy main branch key is not exposed as a typed option" = optionAt real legacy == null;
      "option declarations include all shipped read keys" = lib.all (key: lib.isOption (optionAt real key)) shippedKeys;
      "widening the sidecar enum makes its new value merge" = settingAt widened ["branchless" "test" "strategy"] "probe" == "probe";
      "write-only sidecar key is reported but does not become an option" =
        builtins.attrNames writeOnly.report.excluded
        == [legacy "branchless.probe.written"]
        && optionAt writeOnly "branchless.probe.written" == null;
    }
    && checkRows "branchless defaults and refinements" {
      "a newly extracted builtin shadows a formerly valid revset alias" = rejectsChange (surface:
        settingAt surface ["branchless" "revsets" "alias"] {mine = "@";}) {
        valid = real;
        invalid = newBuiltin;
        expected.mine = "@";
      };
      "jobs accepts zero for automatic CPU sizing but rejects negative values" = rejectsChange (settingAt real ["branchless" "test" "jobs"]) {
        valid = 0;
        invalid = -1;
        expected = 0;
      };
      "omitted alias families stay empty instead of inventing aliases" =
        lib.all (key: lib.getAttrFromPath (pathFor key) unset == {}) familyKeys;
      "revset builtin names are still valid test alias names" = testAlias {draft = "true";} == {draft = "true";};
      "test aliases reject a dot that Git treats as a subsection separator" = rejectsTestAlias "ci.full";
      "test aliases reject underscores outside the plain-name alphabet" = rejectsTestAlias "my_x";
    }
    && checkRows "branchless generator diagnostics" {
      "a key that is both a leaf and a parent prevents option generation" = rejectsChange (surface: builtins.attrNames surface.options) {
        valid = real;
        invalid = nested;
        expected = ["branchless"];
      };
      "an empty enum is reported as lacking a usable type" = emptyEnum.report.untyped == ["branchless.probe.enum"];
      "collision diagnostics name all three settings blocked by the new parent key" =
        nested.report.collisions == ["branchless.test / branchless.test.alias.<name>" "branchless.test / branchless.test.jobs" "branchless.test / branchless.test.strategy"];
      "shipped hand tables still match their source keys and refinement types" =
        real.report.staleExclusions == [] && real.report.staleRefinements == [];
      "the exclusion is stale if its legacy key disappears" = (without legacy).report.staleExclusions == [legacy];
      "the jobs refinement is stale if its key stops being an integer" =
        (withSetting "branchless.test.jobs" {type = "string";}).report.staleRefinements == ["branchless.test.jobs"];
      "unsupported types are reported and excluded from lowering" =
        unmapped.report.untyped == ["branchless.probe.odd"] && map (leaf: leaf.key) unmapped.leaves == shippedKeys;
    }
  );
}
