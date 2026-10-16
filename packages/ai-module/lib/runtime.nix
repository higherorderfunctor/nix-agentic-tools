# Layer 1: `ai.<name>.{activation,files,legacyLedgers}` forward to the root.
# `_file` attributes the forwarded definitions to this file, the one root
# writer the module-provenance guard exempts. Keys in `shared` forward without
# a claim, so their composer stays the single owner.
{
  enabled,
  name,
  shared ? [],
}: {
  config,
  lib,
  options,
  pkgs ? null,
  ...
}: let
  activation = import ./activation.nix {inherit lib;};
  fileLib = import ./files/default.nix {inherit lib pkgs;};
  own = config.ai.${name};
  # Nested priority wrappers travel with the definitions; the wrapper keeps an
  # option-wide `mkDefault`/`mkForce` from re-entering at ordinary priority.
  forward = option: lib.modules.mkAliasAndWrapDefsWithPriority lib.id options.ai.${name}.${option};
in {
  _file = toString ./runtime.nix;
  # The root options it forwards into, for an owner evaluated without the
  # backend modules; a path import, so it deduplicates with theirs.
  imports = [../modules/common.nix];

  options.ai.${name} = {
    activation = lib.mkOption {
      type = lib.types.attrsOf activation.entryType;
      default = {};
    };
    files = lib.mkOption {
      type = lib.types.attrsOf fileLib.entryType;
      default = {};
    };
    legacyLedgers = lib.mkOption {
      type = lib.types.listOf fileLib.legacyLedgerType;
      default = [];
      internal = true;
      # Internal alone still lists the entry's sub-options in option docs.
      visible = false;
    };
  };

  config = lib.mkMerge [
    # Ungated: release commands (`runWhenDisabled`) and old ledgers must reach
    # the engine while the owner is disabled. Every other command follows the
    # owner's state unless its producer sets `enable`; the defaults share the
    # forwarded priority so an option-wide default cannot drop the commands.
    {
      ai.activation = lib.mkMerge [
        (forward "activation")
        (lib.mkOverride options.ai.${name}.activation.highestPrio
          (lib.genAttrs (builtins.attrNames own.activation) (_: {enable = lib.mkDefault enabled;})))
      ];
      ai.legacyLedgers = forward "legacyLedgers";
    }
    (lib.mkIf enabled {
      ai.files = forward "files";
      # Every declared key is a claim, a disabled one included: its `enable =
      # false` would otherwise silently disable another runtime's entry.
      ai.filesOwners = lib.genAttrs (lib.subtractLists shared (builtins.attrNames own.files)) (_: [name]);
    })
  ];
}
