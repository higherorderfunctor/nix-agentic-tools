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
    allowed = ["entries[].name" "opaque.anything" "permissions.allow" "services.*.url" "services.custom.url"];
    value = {};
  };
  unused = keys.inspect {
    known = literalNames;
    allowOptionPath = ["allowed"];
    allowed = ["chat.futureSetting"];
    value."chat.futureSetting" = true;
  };
  credential = keys.check {
    name = "myAPIToken";
    optionPath = ["settings"];
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
  ownerReasons = {identity = "the caller owns identity.";};
  refusedType = keys.refuse {
    type = lib.types.attrsOf lib.types.anything;
    reasons = ownerReasons;
  };
  merge = value:
    refusedType.merge ["settings"] [
      {
        inherit value;
        file = "fixture";
      }
    ];
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
    refusal = let
      owner = keys.check {
        name = "identity";
        optionPath = ["settings"];
        reasons = ownerReasons;
      };
      ownerToken = keys.check {
        name = "myAPIToken";
        reasons.myAPIToken = "the owner supplies the token reason";
      };
      attempt = value: builtins.tryEval (builtins.deepSeq (merge value) true);
      # Credential names are refused at every depth, through maps and lists;
      # owner reasons name top-level fields only.
      nestedOwner = {future.identity = true;};
    in
      !owner.assertion
      && ownerToken.reason == "the owner supplies the token reason"
      && owner.reason == ownerReasons.identity
      && owner.message == "settings.identity cannot be set: the caller owns identity."
      && !(attempt {identity = {nested = true;};}).success
      && !(attempt {myAPIToken = null;}).success
      && !(attempt {future.metadata.access_token = "x";}).success
      && !(attempt {future = [{nested.myAPIToken = "x";}];}).success
      && merge nestedOwner == nestedOwner
      && merge ordinaryValue == ordinaryValue;
    stale =
      length stale.warnings
      == 5
      && lib.hasInfix "`entries[].name` is already declared" (builtins.head stale.warnings)
      && lib.hasInfix "is under an unchecked freeform container" (builtins.elemAt stale.warnings 1)
      && lib.hasInfix "is already declared" (builtins.elemAt stale.warnings 2)
      && lib.hasInfix "`services.*.url` is already declared" (builtins.elemAt stale.warnings 3)
      && lib.hasInfix "`services.custom.url` is accepted under a user-named map" (builtins.elemAt stale.warnings 4);
    unused =
      length unused.warnings
      == 2
      && lib.hasInfix "unrecognized key" (builtins.head unused.warnings)
      && builtins.elemAt unused.warnings 1 == "allowed: allowlist entry `chat.futureSetting` matches no unrecognized setting; remove it or quote dotted segments."
      && allowed.warnings == [];
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
