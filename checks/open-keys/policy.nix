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
      paths = ["entries[].source|0.url" "entries[].source|1.path" "services.*.source|0.url" "services.*.source|1.path"];
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
    allowed = ["services.*.ul" ''"future.key"''];
    value = {
      "future.key" = 42;
      services.custom.ul = "ok";
    };
  };
  stale = keys.inspect {
    inherit known;
    allowOptionPath = ["allowed"];
    allowed = ["opaque.anything" "permissions.allow" "services.*.url"];
    value = {};
  };
  credential = keys.check {
    name = "myAPIToken";
    optionPath = ["settings"];
  };
  owner = keys.check {
    name = "identity";
    reasons.identity = "the login owns this identity";
  };
  overridden = keys.check {
    name = "client_secret";
    reasons.client_secret = "use a credential reader\n";
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
      && credential.reason == "token fields carry authentication material"
      && lib.hasInfix credential.reason credential.message;
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
    note-newline = let
      warning =
        builtins.head
        (keys.inspect {
          inherit known;
          value.future = true;
          notes.future = "the owner note";
        }).warnings;
    in
      lib.hasSuffix "\nthe owner note" warning;
    owner =
      !owner.assertion
      && lib.hasInfix "the login owns this identity" owner.message
      && !overridden.assertion
      && overridden.reason == "use a credential reader\n"
      && overridden.message == "client_secret cannot be set: use a credential reader.";
    passthrough = ordinary.value == ordinaryValue && length ordinary.warnings == 1;
    printed-allowlist = lib.all ({
      entry,
      value,
    }: let
      warning = builtins.head (inspect value).warnings;
      remedy = builtins.elemAt (lib.splitString "\n" warning) 1;
      # Read the exact Nix list in the diagnostic, as a consumer would paste it.
      rendered = lib.removeSuffix " to allowed." (lib.removePrefix "To suppress this warning, add " remedy);
      entries = import (builtins.toFile "open-keys-printed-allowlist.nix" rendered);
    in
      entries
      == [entry]
      && (keys.inspect {
        inherit known value;
        allowed = entries;
      }).warnings
      == []) [
      {
        entry = "entries[].nme";
        value.entries = [{nme = "typo";}];
      }
      {
        entry = "services.*.ul";
        value.services."user.with.dots".ul = "typo";
      }
      {
        entry = ''"future.key"'';
        value."future.key" = true;
      }
      {
        entry = ''"future.\"quoted\""'';
        value."future.\"quoted\"" = true;
      }
      {
        entry = ''"future.''${name}"'';
        value."future.\${name}" = true;
      }
      {
        entry = ''services.*."future.key"'';
        value.services."user.with.dots"."future.key" = true;
      }
    ];
    stale =
      length stale.warnings
      == 3
      && lib.hasInfix "is under an unchecked freeform container" (builtins.head stale.warnings)
      && lib.hasInfix "is already declared" (builtins.elemAt stale.warnings 1)
      && lib.hasInfix "is accepted under a user-named map" (builtins.elemAt stale.warnings 2);
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
