# lib/extracted/options.nix and render.nix over fixture node trees, evaluated
# here. Each case names the refused input or the visible result.
# Then every owner that exports `settingsType` (discovered from `self.lib`,
# so a new owner is covered on arrival) must have an empty report; its loader
# check (`<owner>-settings`) proves the render loads.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  generate = args: import ../../lib/extracted/options.nix {inherit lib;} ({tool = "probe";} // args);
  inherit (import ../../lib/extracted/render.nix {inherit lib;}) render;
  redact = import ../../lib/redact {inherit lib;};
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  merged = type: value:
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption {inherit type;};
          config.value = value;
        }
      ];
    }).config.value;
  accepts = type: value: !(throws (merged type value));
  # Force the real option merge and read the field the restriction protects.
  restricts = type: read: harness.rejectsChange (value: read (merged type value));
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
    "group.key-file" = {
      secretFile = "a key file";
      type = "string";
    };
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
    # Each rejection reads back the valid control through the same merge.
    duration-takes-zero = (merged settings {group.wait = "0";}).group.wait == "0";
    duration-units = restricts settings (value: value.group.wait) {
      valid.group.wait = "1h2m3.5s";
      invalid.group.wait = "5 minutes";
      expected = "1h2m3.5s";
    };
    enum-members = restricts settings (value: value.group.mode) {
      valid.group.mode = "a";
      invalid.group.mode = "c";
      expected = "a";
    };
    every-leaf-takes-null = merged (typeOf {type = "int";}) null == null;
    list-of-objects = restricts settings (value: value.items) {
      valid.items = [{name = "x";}];
      invalid.items = [
        {
          bogus = "x";
          name = "x";
        }
      ];
      expected = [{name = "x";}];
    };
    map-of-strings = restricts settings (value: value.labels) {
      valid.labels.a = "x";
      invalid.labels.a = 1;
      expected.a = "x";
    };
    number-takes-a-float = merged (typeOf {type = "number";}) 1.5 == 1.5;
    objects-are-closed = restricts settings (value: value.group.port) {
      valid.group.port = 1;
      invalid.group = {
        port = 1;
        unknown = 1;
      };
      expected = 1;
    };
    secret-needs-a-reference = restricts settings (value: value.group.token) {
      valid.group.token = file;
      invalid.group.token = "cleartext";
      expected = file;
    };
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
      refined.report.staleRefinements
      == []
      && restricts refined.options.key.type lib.id {
        valid = "1s";
        invalid = "x";
        expected = "1s";
      };
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
      && (merged refined.type {ids = ["x"];}).ids == ["x"]
      && restricts refined.type (value: value.other) {
        valid.other = [file];
        invalid.other = ["cleartext"];
        expected = [file];
      };
    # A row on a list node gets the generated element type, so it can refuse
    # null elements and keep the element shape.
    refinement-sees-the-list-element-type = let
      refined = generate {
        nodes = {
          list.type = "list";
          "list[]".type = "int";
        };
        refinements.list = {
          type = "list";
          refine = {
            elementType,
            types,
            ...
          }:
            types.listOf elementType;
        };
      };
      listType = refined.options.list.type;
    in
      refined.report.staleRefinements
      == []
      && harness.checkRows "refined list elements" (lib.mapAttrs (_: invalid:
        restricts listType lib.id {
          inherit invalid;
          valid = [1 2];
          expected = [1 2];
        }) {
        rejects-null = [1 null];
        rejects-string = [1 "x"];
      });
    # elementType is passed only to a row on a list node that has a `[]` node:
    # an `any` node with a `[]` child and a bare list get none.
    refinement-sees-no-element-type-without-a-list-element = let
      # The refinement yields int only when it did not receive elementType.
      lacksElementType = type: nodes: let
        built = generate {
          inherit nodes;
          refinements.list = {
            inherit type;
            refine = args:
              if args ? elementType
              then args.types.bool
              else args.types.int;
          };
        };
        listType = built.options.list.type;
      in
        built.report.staleRefinements == [] && accepts listType 1 && !(accepts listType true);
    in
      lacksElementType "any" {
        list.type = "any";
        "list[]".type = "int";
      }
      && lacksElementType "list" {list.type = "list";};
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
          secret-file = {
            secretFile = "a key file";
            type = "string";
          };
        };
        refinements = lib.genAttrs ["changed" "gone" "secret" "secret-file"] (_: {
          type = "string";
          refine = {types, ...}: types.str;
        });
      })
      .report
      .staleRefinements
      == ["changed" "gone" "secret" "secret-file"];
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
    # A sample must exercise the generated tree, not just be an accepted
    # empty object (every option is nullable).
    sample-fits-the-type = let
      sample = full.sample {};
    in
      builtins.attrNames sample
      == ["extra" "group" "items" "labels" "secret-items" "secret-labels"]
      && builtins.attrNames sample.group == ["key-file" "mode" "port" "token" "wait"]
      && builtins.attrNames (lib.head sample.items) == ["name"]
      && builtins.attrNames sample.labels == ["sample"]
      && builtins.length sample.secret-items == 1
      && builtins.attrNames sample.secret-labels == ["sample"]
      && accepts settings sample;

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
      typed = merged settings {
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
    # A secret file's placeholder keeps the tag, so the launcher fills it with
    # a path; a plain reference beside it, its null sibling dropped first,
    # still fills with the value.
    render-lifts-a-secret-file = let
      rendered = render {
        prefix = "PROBE";
        settings = {
          key-file = {_redact.asFile = file;};
          token = {
            inherit (file) _redact;
            x = null;
          };
          bearer = {_redact.concat = ["literal " file];};
        };
      };
    in
      rendered.content
      == builtins.toJSON {
        bearer = "{" + "$" + "PROBE_BEARER}";
        key-file = "{" + "$" + "PROBE_KEY_FILE}";
        token = "{" + "$" + "PROBE_TOKEN}";
      }
      && rendered.secrets
      == {
        PROBE_BEARER = {_redact.concat = ["literal " file];};
        PROBE_KEY_FILE = {_redact.asFile = file;};
        PROBE_TOKEN = file;
      };
  };

  # A refinement returns the whole node type. These paths cover its list,
  # map and object shapes; `secretFile` is a redacted descendant too.
  secretLeaf = {
    secret = "a credential";
    type = "string";
  };
  widening = type: path: extra: {
    expr = ''
      (generate {
        nodes = builtins.fromJSON ${builtins.toJSON (builtins.toJSON ({
          ids.type = type;
          ${path} = secretLeaf;
        }
        // extra))};
        refinements.ids = {
          type = ${builtins.toJSON type};
          refine = {types, ...}: types.listOf types.str;
        };
      }).options
    '';
    names = ["refinement rows sit on a node with a secret descendant" "ids -> ${path}"];
  };
  # `_redact` is reserved even inside untyped lists. A malformed marker
  # is refused at its path, never written as data.
  malformedMarker = marker: {
    expr = ''
      render {
        prefix = "PROBE";
        settings.free.nested = builtins.fromJSON ${builtins.toJSON (builtins.toJSON [marker])};
      }
    '';
    names = ["lib/extracted/render: PROBE.free.nested.0: refused a value that is not a redact reference"];
  };
  refused = {
    malformed-concat = malformedMarker {_redact.concat = ["literal"];};
    malformed-reference = malformedMarker {
      _redact.file = "/run/x";
      x = 1;
    };
    refinement-over-list-element = widening "list" "ids[]" {};
    refinement-over-list-field = widening "list" "ids[].token" {"ids[]".type = "object";};
    refinement-over-map-entry = widening "map" "ids.<name>" {};
    refinement-over-object-field = widening "object" "ids.token" {};
    refinement-over-secret-file = widening "list" "ids[]" {
      "ids[]" = {
        secretFile = "a key file";
        type = "string";
      };
    };
    sample-stale-override = {
      expr = ''(generate {nodes.key.type = "bool";}).sample {overrides.gone = 1;}'';
      names = ["sample overrides name no node: gone"];
    };
    secret-and-secret-file = {
      expr = ''(generate {nodes.key = {secret = "a credential"; secretFile = "a key file"; type = "string";};}).options'';
      names = ["nodes are both `secret` and `secretFile`: key"];
    };
    shared-placeholder = {
      expr = ''render {prefix = "PROBE"; settings = {a-b = file; a_b = file;};}'';
      names = ["PROBE: paths share a placeholder name: PROBE_A_B" "a-b, a_b"];
    };
    unknown-field = {
      expr = ''(generate {nodes.key = {range = [0 1]; type = "bool";};}).options'';
      names = ["key: unknown field `range`"];
    };
  };
  # Keep the options and renderer's relative import of redact intact.
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [../../lib/extracted/options.nix ../../lib/extracted/render.nix ../../lib/redact];
  };
  runner = (import ./runner.nix {inherit lib pkgs;}).nix;
  runRefusal = label: case:
    runner {
      inherit label;
      inherit (case) names;
      expr = ''
        let
          lib = import ${pkgs.path}/lib;
          generate = args: import ${source}/lib/extracted/options.nix {inherit lib;} (args // {tool = "probe";});
          inherit (import ${source}/lib/extracted/render.nix {inherit lib;}) render;
          file = (import ${source}/lib/redact {inherit lib;}).file "/run/secrets/probe";
        in ${case.expr}
      '';
    };

  owners = lib.filterAttrs (_: exported: builtins.isAttrs exported && exported ? settingsType) self.lib;
  ownerCases = lib.mapAttrs' (owner: exported:
    lib.nameValuePair "${owner}-report-is-empty" (lib.all (list: list == []) (builtins.attrValues exported.report)))
  owners;

  untypedCases = import ./untyped-settings.nix {inherit harness lib self;};
in {
  checks.extracted-options = assert harness.checkRows "extracted-options" (fixtures // ownerCases // untypedCases // {owners-discovered = ownerCases != {};});
    pkgs.runCommand "extracted-options" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatStrings (lib.mapAttrsToList runRefusal refused)}
      echo "PASS: extracted-options" > "$out"
    '';
}
