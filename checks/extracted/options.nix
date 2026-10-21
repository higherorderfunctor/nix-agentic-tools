# lib/extracted/options.nix and render.nix over fixture node trees, evaluated
# here (no build). Each case names the refused input or the visible result.
# Then every owner that exports `settingsType` (discovered from `self.lib`,
# so a new owner is covered on arrival) must have an empty report; its loader
# check (`<owner>-settings`) proves the render loads.
{
  harness,
  lib,
  self,
  ...
}: let
  generate = args: import ../../lib/extracted/options.nix {inherit lib;} ({tool = "probe";} // args);
  inherit (import ../../lib/extracted/render.nix {inherit lib;}) fill render;
  redact = import ../../lib/redact {inherit lib;};
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  # Whether `type` takes `value` as a definition.
  accepts = type: value:
    !(throws
      (lib.evalModules {
        modules = [
          {
            options.value = lib.mkOption {inherit type;};
            config.value = value;
          }
        ];
      })
      .config
      .value);
  one = node: generate {nodes.key = node;};
  typeOf = node: (one node).options.key.type;
  tree = {
    group.type = "object";
    "group.port".type = "int";
    "group.mode" = {
      enum = ["a" "b"];
      type = "string";
    };
    "group.token" = {
      secret = "a credential";
      type = "string";
    };
    "group.wait".type = "duration";
    items.type = "list";
    "items[]".type = "object";
    "items[].name".type = "string";
    labels.type = "map";
    "labels.<name>".type = "string";
    secret-items.type = "list";
    "secret-items[]" = {
      secret = "a credential";
      type = "string";
    };
    secret-labels.type = "map";
    "secret-labels.<name>" = {
      secret = "a credential";
      type = "string";
    };
    extra.type = "any";
    "extra.known".type = "bool";
  };
  full = generate {nodes = tree;};
  settings = full.type;
  file = redact.file "/run/secrets/probe";

  fixtures = {
    every-leaf-defaults-to-null = (one {type = "bool";}).options.key.default == null;
    every-leaf-takes-null = accepts (typeOf {type = "int";}) null;
    objects-are-closed = !(accepts settings {group.unknown = 1;});
    objects-take-their-keys = accepts settings {group.port = 1;};
    enum-takes-its-values = accepts settings {group.mode = "a";} && !(accepts settings {group.mode = "c";});
    secret-refuses-a-string = !(accepts settings {group.token = "cleartext";});
    secret-takes-a-reference = accepts settings {group.token = file;};
    duration-takes-go-grammar = accepts settings {group.wait = "1h2m3.5s";} && accepts settings {group.wait = "0";};
    duration-refuses-prose = !(accepts settings {group.wait = "5 minutes";});
    list-of-objects = accepts settings {items = [{name = "x";}];} && !(accepts settings {items = [{bogus = "x";}];});
    map-of-strings = accepts settings {labels.a = "x";} && !(accepts settings {labels.a = 1;});
    any-takes-json = accepts settings {extra = {nested = [1 "two" {three = true;}];};};
    number-takes-a-float = accepts (typeOf {type = "number";}) 1.5;
    unknown-field-fails = throws (one {
      type = "bool";
      range = [0 1];
    });
    unread-field-passes =
      !(throws (generate {
        nodes.key = {
          type = "bool";
          readBy = ["probe"];
        };
        unread = ["readBy"];
      }));
    exclusion-drops-the-option =
      !((generate {
        exclusions.key = "probe";
        nodes.key.type = "bool";
      })
        .options
        ? key);
    refinement-replaces-the-type = let
      refined = generate {
        nodes.key.type = "string";
        refinements.key = {
          type = "string";
          refine = {types, ...}: types.duration;
        };
      };
    in
      refined.report.staleRefinements == [] && !(accepts refined.options.key.type "x");
    # A refinement returns the whole value type, so on a container it would
    # replace a redacted descendant: refused, for list, map and object rows.
    refinement-over-a-secret-descendant-is-refused = let
      row = {
        type = "list";
        refine = {types, ...}: types.listOf types.str;
      };
      refined = path: nodes:
        generate {
          inherit nodes;
          refinements.${path} = row // {type = nodes.${path}.type;};
        };
      secretLeaf = {
        secret = "a credential";
        type = "string";
      };
    in
      throws
      (refined "ids" {
        ids.type = "list";
        "ids[]" = secretLeaf;
      }).options
      && throws
      (refined "ids" {
        ids.type = "list";
        "ids[]".type = "object";
        "ids[].token" = secretLeaf;
      }).options
      && throws
      (refined "ids" {
        ids.type = "map";
        "ids.<name>" = secretLeaf;
      }).options
      && throws
      (refined "ids" {
        ids.type = "object";
        "ids.token" = secretLeaf;
      }).options;
    # Rows that would not apply are reported stale, not thrown: a node type
    # that differs from the row's, and a node that is itself secret.
    refinement-guard-ignores-rows-that-would-not-apply = let
      secretLeaf = {
        secret = "a credential";
        type = "string";
      };
      row = type: {
        inherit type;
        refine = {types, ...}: types.listOf types.str;
      };
      typeMismatch = generate {
        nodes = {
          ids.type = "list";
          "ids[]" = secretLeaf;
        };
        refinements.ids = row "map";
      };
      secretNode = generate {
        nodes = {
          ids = secretLeaf // {type = "list";};
          "ids[]" = secretLeaf;
        };
        refinements.ids = row "list";
      };
    in
      typeMismatch.report.staleRefinements
      == ["ids"]
      && secretNode.report.staleRefinements == ["ids"];
    refinement-on-a-list-without-secrets-works = let
      refined = generate {
        nodes = {
          ids.type = "list";
          "ids[]".type = "string";
          other.type = "list";
          "other[]" = {
            secret = "a credential";
            type = "string";
          };
        };
        refinements.ids = {
          type = "list";
          refine = {types, ...}: types.nonEmptyListOf types.str;
        };
      };
    in
      refined.report.staleRefinements
      == []
      && accepts refined.type {ids = ["x"];}
      && !(accepts refined.type {ids = [];})
      && !(accepts refined.type {other = ["cleartext"];});
    # A row whose path is gone, whose node type changed, or whose node is a
    # secret (no row widens a secret) is stale.
    stale-refinements-are-reported =
      (generate {
        nodes = {
          changed.type = "int";
          secret = {
            secret = "a credential";
            type = "string";
          };
        };
        refinements = lib.genAttrs ["changed" "gone" "secret"] (_: {
          type = "string";
          refine = {types, ...}: types.str;
        });
      })
      .report
      .staleRefinements
      == ["changed" "gone" "secret"];
    stale-exclusions-are-reported =
      (generate {
        exclusions.gone = "probe";
        nodes.key.type = "bool";
      })
      .report
      .staleExclusions
      == ["gone"];
    untyped-nodes-are-reported =
      (generate {
        nodes = {
          bare.type = "list";
          odd.type = "union";
        };
      })
      .report
      .untyped
      == ["bare" "odd"];
    misplaced-nodes-are-reported =
      (generate {
        nodes = {
          "orphan.child".type = "bool";
          scalar.type = "string";
          "scalar.child".type = "bool";
        };
      })
      .report
      .misplaced
      == ["orphan.child" "scalar.child"];
    any-consumes-its-children = full.report.misplaced == [] && full.report.untyped == [];
    sample-fits-the-type = accepts settings (full.sample {});
    sample-stale-override-fails = throws (full.sample {overrides.gone = 1;});

    render-drops-nulls-and-lifts-secrets = let
      rendered = render {
        prefix = "PROBE";
        settings = {
          a = null;
          b = [null {c = null;} file];
          d.token-x = file;
        };
      };
    in
      rendered.content
      == builtins.toJSON {
        b = [{} ("{" + "$" + "PROBE_B_1}")];
        d.token-x = "{" + "$" + "PROBE_D_TOKEN_X}";
      }
      && rendered.secrets
      == {
        PROBE_B_1 = file;
        PROBE_D_TOKEN_X = file;
      };
    typed-container-nulls-render-unset = let
      typed =
        (lib.evalModules {
          modules = [
            {
              options.value = lib.mkOption {type = settings;};
              config.value = {
                items = [null {name = "x";}];
                labels = {
                  absent = null;
                  present = "x";
                };
                secret-items = [null file];
                secret-labels = {
                  absent = null;
                  present = file;
                };
              };
            }
          ];
        }).config.value;
      rendered = render {
        prefix = "PROBE";
        settings = typed;
      };
    in
      builtins.fromJSON rendered.content
      == {
        items = [{name = "x";}];
        labels.present = "x";
        secret-items = [("{" + "$" + "PROBE_SECRET_ITEMS_0}")];
        secret-labels.present = "{" + "$" + "PROBE_SECRET_LABELS_PRESENT}";
      }
      && rendered.secrets
      == {
        PROBE_SECRET_ITEMS_0 = file;
        PROBE_SECRET_LABELS_PRESENT = file;
      };
    render-refuses-a-shared-name = throws (render {
      prefix = "PROBE";
      settings = {
        a-b = file;
        a_b = file;
      };
    });
    fill-encodes-json = let
      rendered = render {
        prefix = "PROBE";
        settings.key = file;
      };
    in
      builtins.fromJSON (fill {PROBE_KEY = "q\"\\'";} rendered.content) == {key = "q\"\\'";};
  };

  owners = lib.filterAttrs (_: exported: builtins.isAttrs exported && exported ? settingsType) self.lib;
  ownerCases = lib.mapAttrs' (owner: exported:
    lib.nameValuePair "${owner}-report-is-empty" (lib.all (list: list == []) (builtins.attrValues exported.report)))
  owners;

  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) (fixtures // ownerCases));
in {
  checks.extracted-options = harness.mkTest "extracted-options" (
    assert lib.assertMsg (failures == [] && ownerCases != {}) "extracted-options: FAILED ${builtins.toJSON failures}"; true
  );
}
