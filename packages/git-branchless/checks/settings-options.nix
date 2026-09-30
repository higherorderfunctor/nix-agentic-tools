# The typed git-branchless options follow packages/git-branchless/extracted.json.
#
# ../lib/default.nix generates them, through lib/git-tool-settings, from the
# committed sidecar. Agreement with the real sidecar alone would also hold for a hand-copied option list, so the
# cases that matter run the same generator over FIXTURE sidecars — a key added,
# a key removed, an enum widened, a builtin revset added, a type nothing maps —
# and require the option surface to move with it. Each case is named in the
# failure message.
{
  lib,
  pkgs,
  ...
}: let
  committed = builtins.fromJSON (builtins.readFile ../extracted.json);
  surfaceFor = extracted: (import ../lib/default.nix).git-branchless.settings {inherit extracted lib;};
  real = surfaceFor committed;
  sorted = lib.sort (a: b: a < b);
  setting = key: node: {settings.${key} = node;};
  withSettings = patch: lib.recursiveUpdate committed patch;
  without = key: committed // {settings = builtins.removeAttrs committed.settings [key];};
  read = {reads."probe.rs#get_probe" = ["repository"];};

  added = surfaceFor (withSettings (setting "branchless.probe.added" (read
    // {
      type = "bool";
      default = false;
    })));
  removed = surfaceFor (without "branchless.smartlog.reverse");
  widened = surfaceFor (withSettings {
    settings."branchless.test.strategy".values = committed.settings."branchless.test.strategy".values ++ [{value = "probe";}];
  });
  newBuiltin = surfaceFor (committed // {revsetFunctions = committed.revsetFunctions ++ ["mine"];});
  unmapped = surfaceFor (withSettings (setting "branchless.probe.odd" (read // {type = "u64";})));
  emptyEnum = surfaceFor (withSettings (setting "branchless.probe.enum" (read
    // {
      type = "enum";
      values = [];
    })));
  writeOnly = surfaceFor (withSettings (setting "branchless.probe.written" {
    reads = {};
    type = "string";
    writes."probe.rs#set_probe" = ["file"];
  }));
  nested = surfaceFor (withSettings (setting "branchless.test" (read // {type = "string";})));
  noJobs = surfaceFor (without "branchless.test.jobs");
  retypedJobs = surfaceFor (withSettings {settings."branchless.test.jobs".type = "string";});
  noLegacy = surfaceFor (without "branchless.mainBranch");

  # Does `value` type-check against a closed submodule of `options`?
  accepts = surface: value:
    (builtins.tryEval (builtins.deepSeq
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
      })
      .config
      .settings
      true))
    .success;
  unset =
    (lib.evalModules {
      modules = [
        {
          options.settings = lib.mkOption {
            type = lib.types.submodule {inherit (real) options;};
            default = {};
          };
        }
      ];
    })
    .config
    .settings;
  leafValues = lib.collect (v: !(builtins.isAttrs v) || v == {}) unset;
  optionAt = surface: key: lib.attrByPath (lib.splitString "." (lib.removeSuffix ".<name>" key)) null surface.options;
  keptKeys = sorted (builtins.attrNames (builtins.removeAttrs committed.settings (builtins.attrNames real.report.excluded)));

  cases = {
    # Every key the sidecar keeps is an option leaf, and nothing else is.
    real-surface-is-the-sidecar =
      sorted (map (leaf: leaf.key) real.leaves)
      == keptKeys
      && lib.all (key: lib.isOption (optionAt real key)) keptKeys
      && real.report.excluded ? "branchless.mainBranch"
      && optionAt real "branchless.mainBranch" == null;

    added-key-appears =
      accepts added {branchless.probe.added = true;}
      && !(accepts real {branchless.probe.added = true;});

    removed-key-fails-its-consumer =
      accepts real {branchless.smartlog.reverse = true;}
      && !(accepts removed {branchless.smartlog.reverse = true;});

    enum-follows-the-sidecar =
      accepts widened {branchless.test.strategy = "probe";}
      && !(accepts real {branchless.test.strategy = "probe";})
      && accepts real {branchless.test.strategy = "worktree";};

    # Unset means absent: nothing is set until a consumer sets it.
    unset-is-null =
      leafValues != [] && lib.all (v: v == null || v == {}) leafValues;

    upstream-default-is-described =
      lib.hasInfix "`\"working-copy\"`" (optionAt real "branchless.test.strategy").description
      && lib.hasInfix "physical CPU" (optionAt real "branchless.test.jobs").description
      && lib.hasInfix "never changes the execution strategy" (optionAt real "branchless.test.jobs").description;

    jobs-range =
      accepts real {branchless.test.jobs = 0;}
      && accepts real {branchless.test.jobs = 2147483647;}
      && !(accepts real {branchless.test.jobs = -1;})
      && !(accepts real {branchless.test.jobs = 2147483648;});

    alias-names =
      accepts real {
        branchless.test.alias = {
          ci-full = "nix flake check";
          fast = "true";
        };
      }
      && !(accepts real {branchless.test.alias."ci.full" = "true";})
      && !(accepts real {branchless.test.alias."1st" = "true";})
      && !(accepts real {branchless.test.alias.my_x = "true";})
      # Only revset aliases are shadowed by builtins.
      && accepts real {branchless.test.alias.draft = "true";};

    revset-alias-rejects-builtins =
      accepts real {branchless.revsets.alias.mine = "author.email(me)";}
      && !(accepts real {branchless.revsets.alias.draft = "main()";})
      && !(accepts real {branchless.revsets.alias.Draft = "main()";})
      && !(accepts newBuiltin {branchless.revsets.alias.mine = "author.email(me)";});

    every-type-is-mapped =
      real.report.untyped
      == []
      && unmapped.report.untyped == ["branchless.probe.odd"]
      && emptyEnum.report.untyped == ["branchless.probe.enum"]
      && !(lib.any (leaf: leaf.key == "branchless.probe.odd") unmapped.leaves);

    written-only-keys-are-excluded =
      writeOnly.report.excluded ? "branchless.probe.written"
      && optionAt writeOnly "branchless.probe.written" == null;

    nested-keys-are-reported =
      real.report.collisions
      == []
      && nested.report.collisions == ["branchless.test / branchless.test.alias.<name>" "branchless.test / branchless.test.jobs" "branchless.test / branchless.test.strategy"]
      && !(builtins.tryEval (builtins.deepSeq nested.options true)).success;

    hand-tables-are-current =
      real.report.staleExclusions
      == []
      && real.report.staleRefinements == []
      && noJobs.report.staleRefinements == ["branchless.test.jobs"]
      && retypedJobs.report.staleRefinements == ["branchless.test.jobs"]
      && noLegacy.report.staleExclusions == ["branchless.mainBranch"];
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
in {
  checks.git-branchless-settings-options =
    if failed == []
    then
      pkgs.writeText "git-branchless-settings-options"
      (lib.concatMapStringsSep "\n" (name: "PASS ${name}") (builtins.attrNames cases) + "\n")
    else throw "git-branchless-settings-options: FAILED ${lib.concatStringsSep ", " failed}";
}
