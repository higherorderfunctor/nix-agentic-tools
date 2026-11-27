# lib/git-tool-settings: the shared generator of typed git-tool options.
#
# Two halves, both evaluated here (no build):
#
#   fixtures  the generator over small hand sidecars: a field it does not
#             know FAILS (an extractor that learns a fact must teach the
#             generator, or the fact is dropped), `minimum` narrows the int
#             type, and each optional field reaches the option description.
#   owners    every owner that exports `lib.<owner>.settings` (discovered, so
#             a new tool is covered on arrival): its real sidecar maps every
#             type, nests no keys, and its hand tables are current.
#
# Tool-specific behavior (git-branchless's refinements and exclusions) is
# the owner's own check; see packages/git-branchless/checks/settings-options.nix.
{
  harness,
  lib,
  self,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;

  generate = extracted:
    import ../../lib/git-tool-settings {
      inherit extracted lib;
      # The fixtures state every fact directly, so no row fills one.
      rows = {
        deadKeys = {};
        settings = {};
      };
      tool = "probe-tool";
    };
  read = {reads."probe.rs#read" = ["repository"];};
  sidecar = settings: {
    deadKeys = {};
    foreign = {};
    inherit settings;
    source.version = "1";
  };
  one = node: sidecar {"probe.key" = read // node;};
  optionOf = extracted: (generate extracted).options.probe.key;
  describes = node: fragment: lib.hasInfix fragment (optionOf (one node)).description;

  # Reading the option forces the whole sidecar's schema, including entries
  # that never become options. Each rejection changes only the named field.
  cli = {
    alsoSetBy = ["--force"];
    doc = "Do it";
    flag = "--probe";
  };
  validSidecar =
    lib.recursiveUpdate (one {
      inherit cli;
      default = false;
      invalid = "default";
      type = "bool";
    }) {
      foreign."core.editor" =
        read
        // {
          type = "string";
          writes = {};
        };
      settings."probe.choice" =
        read
        // {
          type = "enum";
          values = [{value = "a";}];
        };
    };
  rejectsSidecar = invalid:
    rejectsChange (extracted: (optionOf extracted).default) {
      valid = validSidecar;
      inherit invalid;
      expected = null;
    };
  schemaCases =
    lib.mapAttrs (_: patch: rejectsSidecar (lib.recursiveUpdate validSidecar patch)) {
      "cli rejects unknown negation field".settings."probe.key".cli.negation = "--no-probe";
      "enum value rejects unknown rank field".settings."probe.choice".values = [
        {
          rank = 1;
          value = "a";
        }
      ];
      "foreign key rejects unknown owner field".foreign."core.editor".owner = "git";
      "setting rejects invalid handling other than default or fallback".settings."probe.key".invalid = "error";
      "setting rejects unknown range field".settings."probe.key".range = [0 1];
      "sidecar rejects unknown aliases field".aliases = [];
    }
    // {
      "sidecar rejects missing deadKeys" = rejectsSidecar (builtins.removeAttrs validSidecar ["deadKeys"]);
    };

  readInt = bounds: value:
    (lib.evalModules {
      modules = [
        {inherit (generate (one ({type = "int";} // bounds))) options;}
        {config.probe.key = value;}
      ];
    }).config.probe.key;
  plainInt = readInt {};
  positiveInt = readInt {minimum = 1;};
  rejectsInt = readValue: valid: invalid:
    rejectsChange readValue {
      inherit invalid valid;
      expected = valid;
    };
  rangeCases = {
    "minimum 1 accepts null" = positiveInt null == null;
    "minimum 1 rejects zero" = rejectsInt positiveInt 1 0;
    "plain int rejects above signed 32-bit maximum" = rejectsInt plainInt (-5) 2147483648;
  };

  # Descriptions tell users the upstream behavior, not Nix's unset default.
  fixtures = {
    cli-or-semantics-are-described = describes {
      inherit cli;
      default = false;
      type = "bool";
    } "`--probe` (also set by `--force`) (\"Do it\") is ORed with this setting";
    computed-terminal-default-is-described = describes {
      defaultExpr = "rr_cache.is_dir()";
      fallback = ["rerere.enabled"];
      type = "bool";
    } "whatever `rr_cache.is_dir()` computes";
    fallback-is-described = describes {
      default = false;
      fallback = ["rebase.autoSquash"];
      type = "bool";
    } "uses the value of `rebase.autoSquash`; when that is unset too, `false`";
    foreign-keys-are-not-options = let
      surface = generate validSidecar;
    in
      !(surface.options ? core) && map (leaf: leaf.key) surface.leaves == ["probe.choice" "probe.key"];
    overrides-are-described = describes {
      overriddenBy = ["--probe" "--no-probe"];
      type = "bool";
    } "flags `--probe`, `--no-probe` override it";
    revset-functions-are-optional = (generate (one {type = "bool";})).revsetFunctions == [];
    silent-fallback-on-invalid-is-described = describes {
      invalid = "default";
      type = "int";
    } "replaces a value it cannot parse with the default";
    special-values-are-described = describes {
      specialValues = ["" "auto"];
      type = "string";
    } "`\"\"`, `\"auto\"`";
    undocumented-is-described = describes {
      documented = false;
      type = "bool";
    } "Undocumented upstream";
  };

  owners = lib.filterAttrs (_: exported: builtins.isAttrs exported && exported ? settings) self.lib;
  ownerCases =
    lib.concatMapAttrs (owner: exported: let
      surface = exported.settings {inherit lib;};
    in {
      "${owner}-hand-tables-are-current" = surface.report.staleExclusions == [] && surface.report.staleRefinements == [];
      "${owner}-keys-do-not-nest" = surface.report.collisions == [];
      "${owner}-options-evaluate" = (builtins.tryEval (builtins.deepSeq surface.options true)).success;
      "${owner}-types-are-mapped" = surface.report.untyped == [];
    })
    owners;
in {
  checks.git-tool-settings-generator = mkTest "git-tool-settings-generator" (
    checkRows "sidecar schema" schemaCases
    && checkRows "integer option definitions" rangeCases
    && checkRows "generated options" fixtures
    && checkRows "owner sidecars" ownerCases
  );
}
