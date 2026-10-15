# cspell:ignore anyof permisions timeot
{
  harness,
  lib,
  ...
}: let
  keys = import ../../lib/open-keys {inherit lib;};
  known = keys.fromPaths {paths = ["entries[].name" "opaque" "permissions.allow" "services.*.url"];};
  inspect = value:
    keys.inspect {
      inherit known value;
      optionPath = ["settings"];
      allowOptionPath = ["allowed"];
    };
  typo = inspect {permisions.allow = [];};
  maps = inspect {
    services = {
      another.url = "ok";
      "user.with.dots".url = "ok";
    };
  };
  mapTypo = inspect {services."user.with.dots".ul = "ok";};
  mixed = keys.inspect {
    known = keys.fromPaths {paths = ["services.*.url" "services.defaults.timeout"];};
    value.services = {
      custom.ul = "ok";
      defaults.timeot = 1;
    };
  };
  lists = inspect {entries = [{name = "ok";} {nme = "typo";}];};
  branches = keys.inspect {
    known = keys.fromPaths {
      mapToken = "<name>";
      paths = ["entries[].source|0.url" "entries[].source|1.path" "services.<name>.source|0.url" "services.<name>.source|1.path"];
    };
    value = {
      entries = [
        {
          source = {
            path = "p";
            url = "u";
          };
        }
      ];
      services.custom.source = {
        path = "p";
        url = "u";
      };
    };
  };
  allowed = keys.inspect {
    inherit known;
    allowed = ["services.*.ul" ["future.key"]];
    value = {
      "future.key" = 42;
      services.custom.ul = "ok";
    };
  };
  stale = keys.inspect {
    inherit known;
    allowOptionPath = ["allowed"];
    allowed = ["opaque.anything" "permissions.allow"];
    value = {};
  };
  credential = keys.check {
    name = "myAPIToken";
    optionPath = ["settings"];
  };
  owner = keys.check {
    name = "identity";
    ignored.identity = "the login owns this identity";
  };
  excluded = keys.check {
    name = "client_secret";
    excluded.client_secret = "use a credential reader";
  };
  ordinaryValue = {
    future = {key = [1 {nested = true;}];};
    opaque."anything.with.dots" = "ok";
  };
  ordinary = inspect ordinaryValue;
  literalNames = keys.fromPaths {
    names = ["chat.modelDefaults"];
    paths = [];
  };
  controls = {
    allowlist = allowed.warnings == [] && allowed.value."future.key" == 42;
    anyof = branches.warnings == [];
    credential =
      !credential.assertion
      && credential.reason == keys.patterns.token
      && lib.hasInfix keys.patterns.token credential.message
      && !(builtins.tryEval (keys.refuse {
        name = "api-key";
        value = "redacted";
      })).success;
    duplicate-list-paths = length (inspect {entries = [{nme = "a";} {nme = "b";}];}).warnings == 1;
    lists = length lists.warnings == 1 && lib.hasPrefix ''settings.entries."[]".nme:'' (builtins.head lists.warnings);
    literal-names =
      (keys.inspect {
        known = literalNames;
        value."chat.modelDefaults"."future.model".field = true;
      }).warnings
      == []
      && (keys.inspect {
        known = literalNames;
        value.chat.modelDefaults = {};
      }).warnings
      != [];
    maps =
      maps.warnings
      == []
      && length mapTypo.warnings == 1
      && lib.hasInfix ''"user.with.dots"'' (builtins.head mapTypo.warnings)
      && length mixed.warnings == 2
      && lib.hasPrefix "services.custom.ul:" (builtins.head mixed.warnings)
      && lib.hasPrefix "services.defaults.timeot:" (builtins.elemAt mixed.warnings 1);
    owner =
      !owner.assertion
      && lib.hasInfix "the login owns this identity" owner.message
      && excluded.reason == "use a credential reader"
      && !(builtins.tryEval (keys.refuse {
        name = "identity";
        ignored.identity = "the login owns this identity";
        value = "redacted";
      })).success;
    passthrough =
      ordinary.value
      == ordinaryValue
      && length ordinary.warnings == 1
      && keys.refuse {
        name = "future";
        value = ordinaryValue;
      }
      == ordinaryValue;
    stale =
      length stale.warnings
      == 2
      && lib.hasInfix "is under an unchecked freeform container" (builtins.head stale.warnings)
      && lib.hasInfix "is already declared" (builtins.elemAt stale.warnings 1);
    typo = length typo.warnings == 1 && lib.hasInfix "did you mean `settings.permissions`?" (builtins.head typo.warnings);
  };
  inherit (builtins) length;
in {
  checks = lib.mapAttrs' (name: passed:
    lib.nameValuePair "open-keys-${name}" (harness.mkTest "open-keys-${name}" (
      assert lib.assertMsg passed "open-keys ${name} contract failed"; true
    )))
  controls;
}
