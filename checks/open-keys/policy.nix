# cspell:ignore nme timeot
{
  harness,
  lib,
  ...
}: let
  inherit (builtins) elemAt head length;
  inherit (harness) checkRows mkTest;
  keys = import ../../lib/open-keys {inherit lib;};
  known = keys.fromPaths {paths = ["entries[].name" "opaque" "services.*.url"];};
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
  literalNames = keys.fromPaths {
    names = ["chat.modelDefaults"];
    paths = [];
  };
  printedEntry = entry: value: let
    actual = warnings {inherit value;};
    lines = lib.splitString "\n" (head actual);
    prefix = "To suppress this warning, add ";
    suffix = " to allowed.";
    remedy = elemAt lines 1;
    # Read the exact Nix list in the diagnostic, as a consumer would paste it.
    rendered = lib.removeSuffix suffix (lib.removePrefix prefix remedy);
    entries = import (builtins.toFile "open-keys-printed-allowlist.nix" rendered);
  in
    length actual
    == 1
    && length lines == 2
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
      "literal schema names do not accept nested copies" = warnsFor ["chat"] (warnings {
        known = literalNames;
        value.chat.modelDefaults = {};
      });
      "map names are unrestricted but dotted names stay quoted in warnings" = warnsFor [''services."user.with.dots".ul''] (warnings {
        value.services = {
          "user.with.dots" = {
            ul = "typo";
            url = "ok";
          };
        };
      });
      "only the unknown root warns, not its children" = warnsFor ["future"] (warnings {
        value.future.key = [1 {nested = true;}];
      });
      "owner note starts on a new line" = let
        actual = warnings {
          notes.future = "the owner note";
          value.future = true;
        };
      in
        warnsFor ["future"] actual && lib.hasSuffix "\nthe owner note" (head actual);
      "stale allowlist distinguishes declared list and wildcard paths from unchecked and concrete map paths" =
        warnings {
          allowed = ["entries[].name" "opaque.anything" "services.*.url" "services.custom.url"];
          value = {};
        }
        == [
          "allowed: stale allowlist entry `entries[].name` is already declared; remove it."
          "allowed: stale allowlist entry `opaque.anything` is under an unchecked freeform container; remove it."
          "allowed: stale allowlist entry `services.*.url` is already declared; remove it."
          "allowed: stale allowlist entry `services.custom.url` is accepted under a user-named map; remove it."
        ];
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
      "wildcard suppression covers multiple map entries without swallowing a sibling" = let
        value.services = {
          custom.extra = true;
          other = {
            extra = "also accepted";
            label = "still unrecognized";
          };
        };
        allowed = inspect {
          inherit value;
          allowed = ["services.*.extra"];
        };
      in
        warnsFor ["services.custom.extra" "services.other.extra" "services.other.label"] (warnings {inherit value;})
        && warnsFor ["services.other.label"] allowed.warnings;
    });
    open-keys-printed-allowlist = mkTest "open-keys-printed-allowlist" (checkRows "printed allowlist round-trip" {
      "dotted map field is quoted and uses the wildcard instead of the entry name" = printedEntry ''services.*."future.key"'' {services."user.with.dots"."future.key" = true;};
      "interpolation in a key is printed literally, not evaluated" = printedEntry ''"future.''${name}"'' {"future.\${name}" = true;};
      "list marker is glued to the list name in the printed entry" = printedEntry "entries[].nme" {entries = [{nme = "typo";}];};
      "quote in a key is escaped in the printed entry" = printedEntry ''"future.\"quoted\""'' {"future.\"quoted\"" = true;};
    });
  };
}
