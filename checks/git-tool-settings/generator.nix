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
  lib,
  pkgs,
  self,
  ...
}: let
  generate = extracted:
    import ../../lib/git-tool-settings {
      inherit extracted lib;
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
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  optionOf = extracted: (generate extracted).options.probe.key;
  describes = node: fragment: lib.hasInfix fragment (optionOf (one node)).description;
  checks' = type: value: (builtins.tryEval (type.check value)).value or false;

  fixtures = {
    known-fields-evaluate =
      !(throws (optionOf (one {
        cli = {
          alsoSetBy = ["--force"];
          doc = "Do it";
          flag = "--probe";
        };
        default = false;
        invalid = "default";
        type = "bool";
      })));
    unknown-setting-field-fails = throws (optionOf (one {
      type = "bool";
      range = [0 1];
    }));
    unknown-top-level-field-fails = throws (generate ((one {type = "bool";}) // {aliases = [];})).options;
    unknown-value-field-fails = throws (optionOf (one {
      type = "enum";
      values = [
        {
          value = "a";
          rank = 1;
        }
      ];
    }));
    unknown-cli-field-fails = throws (optionOf (one {
      type = "bool";
      cli = {
        flag = "--p";
        doc = "";
        negation = "--no-p";
      };
    }));
    unknown-foreign-field-fails =
      throws
      (generate ((one {type = "bool";})
        // {
          foreign."core.x" = {
            reads = {};
            writes = {};
            owner = "git";
          };
        })).options;
    missing-required-field-fails = throws (generate (builtins.removeAttrs (one {type = "bool";}) ["deadKeys"])).options;
    bad-invalid-value-fails = throws (optionOf (one {
      type = "bool";
      invalid = "error";
    }));
    revset-functions-are-optional = (generate (one {type = "bool";})).revsetFunctions == [];
    minimum-narrows-the-int = let
      inherit
        (optionOf (one {
          type = "int";
          minimum = 1;
        }))
        type
        ;
    in
      checks' type 1 && !(checks' type 0) && !(checks' type (-5)) && checks' type null;
    plain-int-is-32-bit = let
      inherit (optionOf (one {type = "int";})) type;
    in
      checks' type (-5) && !(checks' type 2147483648);
    fallback-is-described = describes {
      type = "bool";
      default = false;
      fallback = ["rebase.autoSquash"];
    } "uses the value of `rebase.autoSquash`; when that is unset too, `false`";
    computed-terminal-default-is-described = describes {
      type = "bool";
      defaultExpr = "rr_cache.is_dir()";
      fallback = ["rerere.enabled"];
    } "whatever `rr_cache.is_dir()` computes";
    cli-or-semantics-are-described = describes {
      type = "bool";
      default = false;
      cli = {
        alsoSetBy = ["--force"];
        doc = "Do it";
        flag = "--probe";
      };
    } "`--probe` (also set by `--force`) (\"Do it\") is ORed with this setting";
    overrides-are-described = describes {
      type = "bool";
      overriddenBy = ["--probe" "--no-probe"];
    } "flags `--probe`, `--no-probe` override it";
    undocumented-is-described = describes {
      type = "bool";
      documented = false;
    } "Undocumented upstream";
    silent-fallback-on-invalid-is-described = describes {
      type = "int";
      invalid = "default";
    } "replaces a value it cannot parse with the default";
    special-values-are-described = describes {
      type = "string";
      specialValues = ["" "auto"];
    } "`\"\"`, `\"auto\"`";
    foreign-keys-are-not-options = let
      surface = generate ((one {type = "bool";})
        // {
          foreign."core.editor" = {
            inherit (read) reads;
            writes = {};
            type = "string";
          };
        });
    in
      !(surface.options ? core) && map (l: l.key) surface.leaves == ["probe.key"];
  };

  owners = lib.filterAttrs (_: exported: builtins.isAttrs exported && exported ? settings) self.lib;
  ownerCases =
    lib.concatMapAttrs (owner: exported: let
      surface = exported.settings {inherit lib;};
    in {
      "${owner}-types-are-mapped" = surface.report.untyped == [];
      "${owner}-keys-do-not-nest" = surface.report.collisions == [];
      "${owner}-hand-tables-are-current" = surface.report.staleExclusions == [] && surface.report.staleRefinements == [];
      "${owner}-options-evaluate" = !(throws surface.options);
    })
    owners;

  cases = fixtures // ownerCases;
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
in {
  checks.git-tool-settings-generator =
    if failed == []
    then
      pkgs.writeText "git-tool-settings-generator"
      (lib.concatMapStringsSep "\n" (name: "PASS ${name}") (builtins.attrNames cases) + "\n")
    else throw "git-tool-settings-generator: FAILED ${lib.concatStringsSep ", " failed}";
}
