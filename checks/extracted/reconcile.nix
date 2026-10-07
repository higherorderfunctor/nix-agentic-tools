{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) reconcile withAdded;
  base = {
    facts.value.type = "string";
    fields = ["description" "excluded"];
    needs = ["type"];
    rows.value = {};
    secretNeeds = ["excluded"];
  };
  # Every case names its refused input or the consumer-visible result.
  cases = {
    auto-accept-unrecorded = {
      added = ["value"];
      input.rows = {};
      kinds = ["unrecorded"];
    };
    bad-field = {
      input.rows.value.bogus = true;
      kinds = ["bad-row"];
    };
    bad-ignored = {
      input.rows.value.ignored = " ";
      kinds = ["bad-row"];
    };
    bad-replace = {
      input.rows.value.replace = "type";
      kinds = ["bad-row"];
    };
    bad-row = {
      input.rows.value = null;
      kinds = ["bad-row"];
    };
    boolean-secret-name = {
      input = {
        facts = {token.type = "boolean";};
        rows = {};
      };
      added = ["token"];
      kinds = ["unrecorded"];
    };
    fill-only = {
      input = {
        facts.value.description = null;
        rows.value.description = "hand prose";
      };
      description = "hand prose";
      kinds = [];
    };
    ignored = {
      input = {
        facts.value.type = null;
        rows.value.ignored = "owned by the host";
      };
      entries = [];
      kinds = [];
    };
    needs-human = {
      input.facts.value.type = null;
      kinds = ["needs-human"];
    };
    removed-row = {
      input.facts = {};
      kinds = ["removed"];
    };
    removed-use = {
      input = {
        facts = {};
        rows = {};
        uses.value = "launcher flag";
      };
      kinds = ["removed"];
    };
    replace = {
      input.rows.value = {
        replace = ["type"];
        type = "number";
      };
      kinds = [];
      type = "number";
    };
    secret = {
      input = {
        facts = {token.type = "string";};
        rows = {};
      };
      kinds = ["secret"];
    };
    secret-delivered = {
      input = {
        facts = {token.type = "string";};
        rows = {token.excluded = "runtime file delivery";};
      };
      kinds = [];
    };
    secret-filled-type = {
      input = {
        facts = {token.type = null;};
        rows = {token.type = "string";};
      };
      kinds = ["secret"];
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
      kinds = ["secret"];
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
      kinds = ["secret"];
    };
    shadow = {
      input.rows.value.type = "number";
      kinds = ["bad-row"];
      type = "string";
    };
    struct-secret-name = {
      input = {
        facts = {token.type = "object";};
        rows = {};
      };
      added = ["token"];
      kinds = ["unrecorded"];
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
    map (failure: failure.kind) result.failures
    == case.kinds
    && result.added == (case.added or [])
    && builtins.attrNames result.entries == (case.entries or (builtins.attrNames surface.facts))
    && (!(case ? description) || result.entries.value.description == case.description)
    && (!(case ? type) || result.entries.value.type == case.type);
  failures = builtins.attrNames (lib.filterAttrs (_: case: !(run case)) cases);
  new = reconcile {config = base // {rows = {};};};
  file = withAdded ./rows.json new;
  recorded = reconcile {
    config =
      base
      // {
        facts = base.facts // {existing.type = "string";};
        rows = file.config;
      };
  };
in {
  checks.extracted-reconcile = harness.mkTest "extracted-reconcile" (
    assert lib.assertMsg (failures == []) (builtins.toJSON failures);
    assert file.config.value == {};
    assert file.config.existing.excluded == "runtime file delivery";
    assert file.environmentIgnored.host.reason == "host state";
    assert recorded.config.failures == []; true
  );
}
