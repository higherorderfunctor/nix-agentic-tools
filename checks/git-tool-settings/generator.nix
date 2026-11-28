# lib/git-tool-settings: the shared generator of typed git-tool options.
#
# Two halves, both evaluated here (no build):
#
#   fixtures  the generator over small hand sidecars: a field it does not
#             know FAILS (an extractor that learns a fact must teach the
#             generator, or the fact is dropped), integers keep their type
#             at module merge, and measured prose reaches option descriptions.
#   owners    discover `lib.<owner>.settings` exports and check their type
#             mappings and hand tables unless the owner already does so.
#             Git module parity forces the option tree (including path collision
#             rejection); checks/modules/options-doc.nix forces its prose.
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
      # Dropping `deadKeys` from `schema.required` alone changes the diagnostic, not the rejection this row pins.
      "sidecar rejects missing deadKeys" = rejectsSidecar (builtins.removeAttrs validSidecar ["deadKeys"]);
    };

  plainInt = value:
    (lib.evalModules {
      modules = [
        {inherit (generate (one {type = "int";})) options;}
        {config.probe.key = value;}
      ];
    }).config.probe.key;
  rangeCases = {
    # The bounded and refined integers in checks/git-config/module-eval.nix
    # don't exercise the plain int type: it must be signed and 32-bit too.
    "plain int rejects above signed 32-bit maximum" = rejectsChange plainInt {
      expected = -5;
      invalid = 2147483648;
      valid = -5;
    };
  };

  # Descriptions tell users the upstream behavior, not Nix's unset default.
  descriptionCases = lib.mapAttrs (_: {fragment, ...} @ fixture:
    lib.hasInfix fragment (optionOf (one (builtins.removeAttrs fixture ["fragment"]))).description) {
    "CLI flag and its alias can only turn the setting on" = {
      inherit cli;
      fragment = "`--probe` (also set by `--force`) (\"Do it\") is ORed with this setting: it can only turn it on for one run";
      type = "bool";
    };
    "computed default is shown at the end of a fallback chain" = {
      defaultExpr = "rr_cache.is_dir()";
      fallback = ["rerere.enabled"];
      fragment = "uses the value of `rerere.enabled`; when that is unset too, whatever `rr_cache.is_dir()` computes";
      type = "bool";
    };
    "explicit override flags can beat the setting" = {
      fragment = "flags `--probe`, `--no-probe` override it";
      overriddenBy = ["--probe" "--no-probe"];
      type = "bool";
    };
    "fallback reads another key before using a literal default" = {
      default = false;
      fallback = ["rebase.autoSquash"];
      fragment = "uses the value of `rebase.autoSquash`; when that is unset too, `false`";
      type = "bool";
    };
    "invalid int silently chooses the default, not the fallback" = {
      fragment = "replaces a value it cannot parse with the default, silently";
      invalid = "default";
      type = "int";
    };
    "special values include the empty string, not just auto" = {
      fragment = ''`""`, `"auto"`'';
      specialValues = ["" "auto"];
      type = "string";
    };
    "undocumented setting does not pass for upstream documentation" = {
      documented = false;
      fragment = "Undocumented upstream";
      type = "bool";
    };
  };

  surfaceCases = let
    surface = generate validSidecar;
  in {
    "core.editor is not declared as an option" =
      builtins.attrNames surface.options
      == ["probe"]
      && builtins.attrNames surface.options.probe == ["choice" "key"];
    "tools without a revsetFunctions field expose an empty list" = surface.revsetFunctions == [];
  };

  owners = lib.filterAttrs (_: exported: builtins.isAttrs exported && exported ? settings) self.lib;
  ownerCases =
    lib.concatMapAttrs (owner: exported: let
      surface = exported.settings {inherit lib;};
    in {
      "${owner}: hand tables do not name removed or retyped keys" = surface.report.staleExclusions == [] && surface.report.staleRefinements == [];
      "${owner}: no read option falls back to an unspecified type" = surface.report.untyped == [];
    })
    # packages/git-branchless/checks/settings-options.nix checks these reports on the same sidecar.
    (builtins.removeAttrs owners ["git-branchless"])
    // {
      # Discover future owners, but don't let a lost export silently shrink the check.
      "all three shipped git tool settings exports are discovered" =
        lib.all (owner: owners ? ${owner}) ["git-absorb" "git-branchless" "git-revise"];
    };
in {
  checks.git-tool-settings-generator = mkTest "git-tool-settings-generator" (
    checkRows "sidecar schema" schemaCases
    && checkRows "integer option definitions" rangeCases
    && checkRows "option descriptions" descriptionCases
    && checkRows "generated options" surfaceCases
    && checkRows "owner sidecars" ownerCases
  );
}
