{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) reconcile;
  base = {
    facts.value.type = "string";
    fields = ["aliasFor" "description" "excluded"];
    needs = ["type"];
    rows.value = {};
    secretNeeds = ["excluded"];
  };
  failure = kind: name: details: {
    inherit details kind name;
    surface = "config";
  };
  badRow = failure "bad-row" "value";
  removed = failure "removed";
  secret = name: failure "secret" name ["excluded"];
  # Every case names its refused input or the consumer-visible result.
  cases = {
    bad-field = {
      input.rows.value.bogus = true;
      failures = [(badRow ["bogus"])];
    };
    bad-ignored = {
      input.rows.value.ignored = " ";
      failures = [(badRow ["ignored must give a non-blank reason"])];
    };
    bad-replace = {
      input.rows.value.replace = "type";
      failures = [(badRow ["replace must list supplied allowed fields"])];
    };
    bad-row = {
      input.rows.value = null;
      failures = [(badRow ["row must be an object"])];
    };
    blank-alias = {
      input.rows.value.aliasFor = "";
      failures = [(badRow ["aliasFor"])];
    };
    blank-controls = {
      input = {
        fields = ["controls"];
        rows.value.controls = "";
      };
      failures = [(badRow ["controls"])];
    };
    blank-excluded = {
      input = {
        facts = {token.type = "string";};
        rows.token.excluded = "";
      };
      failures = [(failure "bad-row" "token" ["excluded"]) (secret "token")];
    };
    blank-non-secret-excluded = {
      input.rows.value.excluded = "";
      failures = [(badRow ["excluded"])];
    };
    boolean-secret-name = {
      input = {
        facts = {token.type = "boolean";};
        rows = {};
      };
      failures = [];
    };
    fill-only = {
      input = {
        facts.value.description = null;
        rows.value.description = "hand prose";
      };
      description = "hand prose";
      failures = [];
    };
    ignored = {
      input = {
        facts.value.type = null;
        rows.value.ignored = "owned by the host";
      };
      entries = [];
      failures = [];
    };
    needs-human = {
      input.facts.value.type = null;
      failures = [(failure "needs-human" "value" ["type"])];
    };
    new-name = {
      input.rows = {};
      failures = [];
    };
    # A pattern row fills every fact it matches, a credential included.
    pattern = {
      input = {
        facts = {
          "keys.a[].token".type = "string";
          "keys.b-c[].token".type = "string";
        };
        patterns."keys.*[].token".excluded = "runtime file delivery";
        rows = {};
      };
      failures = [];
      check = result:
        result.entries
        == {
          "keys.a[].token" = {
            excluded = "runtime file delivery";
            type = "string";
          };
          "keys.b-c[].token" = {
            excluded = "runtime file delivery";
            type = "string";
          };
        };
    };
    # A `*` matches one key, never a path.
    pattern-one-key = {
      input = {
        facts."keys.a.b.leaf".type = "string";
        patterns."keys.*.leaf".description = "hand prose";
        rows = {};
      };
      failures = [(removed "keys.*.leaf" "delete the stale pattern row")];
      check = result: !(result.entries."keys.a.b.leaf" ? description);
    };
    pattern-overlap = {
      input = {
        facts."keys.a.leaf".type = "string";
        patterns."keys.*.leaf".description = "hand prose";
        rows."keys.a.leaf".description = "other prose";
      };
      failures = [(failure "bad-row" "keys.a.leaf" ["claimed by several rows: keys.a.leaf, keys.*.leaf"])];
    };
    pattern-pattern-overlap = {
      input = {
        facts."keys.a.leaf".type = "string";
        patterns = {
          "*.a.leaf".description = "other prose";
          "keys.*.leaf".description = "hand prose";
        };
        rows = {};
      };
      failures = [(failure "bad-row" "keys.a.leaf" ["claimed by several rows: *.a.leaf, keys.*.leaf"])];
    };
    pattern-stale = {
      input.patterns."keys.*.leaf".description = "hand prose";
      failures = [(removed "keys.*.leaf" "delete the stale pattern row")];
    };
    removed-row = {
      input = {
        facts = {};
        rows.value.description = "hand prose";
      };
      failures = [(removed "value" "delete the stale row")];
    };
    removed-unused = {
      input = {
        facts = {};
        rows = {};
      };
      failures = [];
    };
    removed-use = {
      input = {
        facts = {};
        rows = {};
        uses.value = "launcher flag";
      };
      failures = [(removed "value" "launcher flag")];
    };
    replace = {
      input.rows.value = {
        replace = ["type"];
        type = "number";
      };
      failures = [];
      type = "number";
    };
    replace-not-allowed = {
      input.rows.value = {
        ignored = "kept";
        replace = ["ignored"];
      };
      entries = [];
      failures = [(badRow ["replace must list supplied allowed fields"])];
    };
    replace-not-supplied = {
      input.rows.value.replace = ["description"];
      failures = [(badRow ["replace must list supplied allowed fields"])];
    };
    secret = {
      input = {
        facts = {token.type = "string";};
        rows = {};
      };
      failures = [(secret "token")];
    };
    secret-delivered = {
      input = {
        facts = {token.type = "string";};
        rows = {token.excluded = "runtime file delivery";};
      };
      failures = [];
    };
    secret-filled-type = {
      input = {
        facts = {token.type = null;};
        rows = {token.type = "string";};
      };
      failures = [(secret "token")];
    };
    secret-map = {
      input = {
        facts = {
          gitTokens = {
            additionalProperties.type = "string";
            type = "object";
          };
        };
        rows = {gitTokens = {};};
      };
      failures = [(secret "gitTokens")];
    };
    secret-no-needs = {
      input = {
        facts = {token.type = "string";};
        rows = {};
        secretNeeds = [];
      };
      failures = [(failure "secret" "token" [])];
    };
    secret-retyped = {
      input = {
        facts = {token.type = "string";};
        rows = {
          token = {
            replace = ["type"];
            type = "number";
          };
        };
      };
      failures = [(secret "token")];
    };
    shadow = {
      input.rows.value.type = "number";
      failures = [(badRow ["type"])];
      type = "string";
    };
    struct-secret-name = {
      input = {
        facts = {token.type = "object";};
        rows = {};
      };
      failures = [];
    };
  };
  run = case: let
    # Replace name maps as whole inputs; merge only the value descriptor and
    # its row when a case fills individual fields.
    input = base // case.input;
    surface =
      input
      // lib.optionalAttrs ((case.input.facts or {}) ? value) {
        facts.value = base.facts.value // case.input.facts.value;
      }
      // lib.optionalAttrs ((case.input.rows or {}) ? value && builtins.isAttrs case.input.rows.value) {
        rows.value = base.rows.value // case.input.rows.value;
      };
    result = (reconcile {config = surface;}).config;
  in
    result.failures
    == case.failures
    && builtins.attrNames result.entries == (case.entries or (builtins.attrNames surface.facts))
    && (!(case ? description) || result.entries.value.description == case.description)
    && (!(case ? type) || result.entries.value.type == case.type)
    && (!(case ? check) || case.check result);
in {
  checks.extracted-reconcile = harness.mkTest "extracted-reconcile" (
    harness.checkRows "extracted-reconcile" (lib.mapAttrs (_: run) cases)
  );
}
