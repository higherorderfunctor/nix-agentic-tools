# cspell:ignore nme permisions timeot
{
  harness,
  lib,
  ...
}: let
  inherit (builtins) head;
  inherit (harness) checkRows mkTest;
  keys = import ../../lib/open-keys {inherit lib;};
  known = keys.fromPaths {paths = ["entries[].name" "opaque" "permissions.allow" "services.*.url"];};
  inspect = args:
    keys.inspect ({
        inherit known;
        allowOptionPath = ["allowed"];
        optionPath = ["settings"];
      }
      // args);
  warnings = args: (inspect args).warnings;
  warningLines = map (warning: head (lib.splitString "\n" warning));
  warnsFor = paths: actual:
    map (line: head (lib.splitString ";" line)) (warningLines actual)
    == map (path: "settings.${path}: unrecognized key") paths;
  credential = name:
    keys.check {
      inherit name;
      optionPath = ["settings"];
    };
  literalNames = keys.fromPaths {
    names = ["chat.modelDefaults"];
    paths = [];
  };
  printedEntry = entry: value: let
    actual = warnings {inherit value;};
    lines = lib.splitString "\n" (head actual);
    prefix = "To suppress this warning, add ";
    suffix = " to allowed.";
    remedy = builtins.elemAt lines 1;
    # Read the exact Nix list in the diagnostic, as a consumer would paste it.
    rendered = lib.removeSuffix suffix (lib.removePrefix prefix remedy);
    entries = import (builtins.toFile "open-keys-printed-allowlist.nix" rendered);
  in
    builtins.length actual
    == 1
    && builtins.length lines == 2
    && lib.hasPrefix prefix remedy
    && lib.hasSuffix suffix remedy
    && entries == [entry]
    && warnings {
      inherit value;
      allowed = entries;
    }
    == [];
in {
  checks = {
    open-keys-policy = mkTest "open-keys-policy" (checkRows "open key inspection" {
      "allowlist suppresses only matching quoted keys and map fields" = let
        value = {
          "future.key" = 42;
          services.custom = {
            extra = true;
            ul = "ok";
          };
        };
        allowed = inspect {
          inherit value;
          allowed = [''"future.key"'' "services.*.ul"];
        };
      in
        allowed.value == value && warnsFor ["services.custom.extra"] allowed.warnings;
      "branch-marked fields are accepted in lists and maps without opening their nodes" = let
        source = {
          extra = true;
          path = "p";
          url = "u";
        };
      in
        warnsFor [''entries."[]".source.extra'' "services.custom.source.extra"] (warnings {
          known = keys.fromPaths {
            paths = ["entries[].source|0.url" "entries[].source|1.path" "services.*.source|0.url" "services.*.source|1.path"];
          };
          value = {
            entries = [{inherit source;}];
            services.custom = {inherit source;};
          };
        });
      "credential refusal names the field and reason" = let
        allowed = credential "displayName";
        refused = credential "myAPIToken";
      in
        allowed.assertion
        && allowed.reason == null
        && !refused.assertion
        && refused.reason == "token fields carry authentication material"
        && refused.message == "settings.myAPIToken cannot be set: token fields carry authentication material.";
      "declared struct children take precedence over a wildcard map" = warnsFor ["services.custom.ul" "services.defaults.timeot" "services.defaults.url"] (warnings {
        known = keys.fromPaths {paths = ["services.*.url" "services.defaults.timeout"];};
        value.services = {
          custom.ul = "ok";
          defaults = {
            timeot = 1;
            timeout = 1;
            url = "not declared here";
          };
        };
      });
      "list warnings name the element path once even across repeated typos" = warnsFor [''entries."[]".nme''] (warnings {
        value.entries = [{name = "ok";} {nme = "a";} {nme = "b";}];
      });
      "literal schema names accept open dotted keys, not nested copies" = warnsFor ["chat"] (warnings {
        known = literalNames;
        value = {
          chat.modelDefaults = {};
          "chat.modelDefaults"."future.model".field = true;
        };
      });
      "map names are unrestricted but dotted names stay quoted in warnings" = warnsFor [''services."user.with.dots".ul''] (warnings {
        value.services = {
          another.url = "ok";
          "user.with.dots" = {
            ul = "typo";
            url = "ok";
          };
        };
      });
      "owner note starts on a new line" = let
        actual = warnings {
          notes.future = "the owner note";
          value.future = true;
        };
      in
        warnsFor ["future"] actual && lib.hasSuffix "\nthe owner note" (head actual);
      "passthrough preserves the unknown payload and unchecked subtree" = let
        value = {
          future.key = [1 {nested = true;}];
          opaque."anything.with.dots" = "ok";
        };
        ordinary = inspect {inherit value;};
      in
        ordinary.value == value && warnsFor ["future"] ordinary.warnings;
      "stale allowlist warnings preserve each entry and classify its redundancy" =
        warnings {
          allowed = ["entries[].name" "opaque.anything" "permissions.allow" "services.*.url" "services.custom.url"];
          value = {};
        }
        == [
          "allowed: stale allowlist entry `entries[].name` is already declared; remove it."
          "allowed: stale allowlist entry `opaque.anything` is under an unchecked freeform container; remove it."
          "allowed: stale allowlist entry `permissions.allow` is already declared; remove it."
          "allowed: stale allowlist entry `services.*.url` is already declared; remove it."
          "allowed: stale allowlist entry `services.custom.url` is accepted under a user-named map; remove it."
        ];
      "typo warns at the misspelled path and suggests the declared sibling" =
        warningLines (warnings {
          value = {
            permissions.allow = [];
            permisions.allow = [];
          };
        })
        == ["settings.permisions: unrecognized key; did you mean `settings.permissions`?"];
      "unquoted dotted suppression is unused and leaves the literal key warning" =
        warningLines (warnings {
          known = literalNames;
          allowed = ["chat.futureSetting"];
          value."chat.futureSetting" = true;
        })
        == [
          ''settings."chat.futureSetting": unrecognized key''
          "allowed: allowlist entry `chat.futureSetting` matches no unrecognized setting; remove it or quote dotted segments."
        ];
    });
    open-keys-printed-allowlist = mkTest "open-keys-printed-allowlist" (checkRows "printed allowlist round-trip" {
      "dotted key" = printedEntry ''"future.key"'' {"future.key" = true;};
      "dotted key under a map" = printedEntry ''services.*."future.key"'' {services."user.with.dots"."future.key" = true;};
      "interpolation in key" = printedEntry ''"future.''${name}"'' {"future.\${name}" = true;};
      "list marker" = printedEntry "entries[].nme" {entries = [{nme = "typo";}];};
      "map wildcard" = printedEntry "services.*.ul" {services."user.with.dots".ul = "typo";};
      "quote in key" = printedEntry ''"future.\"quoted\""'' {"future.\"quoted\"" = true;};
    });
  };
}
