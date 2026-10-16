# Layer 1: `ai.<name>.files2` forwards into `ai.files2` while `enabled`.
{
  enabled,
  name,
}: {
  config,
  lib,
  options,
  pkgs ? null,
  ...
}: let
  files2 = import ./files/default.nix {inherit lib pkgs;};
in {
  options.ai.${name}.files2 = lib.mkOption {
    type = lib.types.attrsOf files2.entryType;
    default = {};
  };

  config = lib.mkIf enabled {
    # Nested priority wrappers travel with the definitions; the wrapper keeps an
    # option-wide `mkDefault`/`mkForce` from re-entering at ordinary priority.
    ai.files2 = lib.modules.mkAliasAndWrapDefsWithPriority lib.id options.ai.${name}.files2;
    # Every declared key is a claim, a disabled one included: its `enable =
    # false` would otherwise silently disable another runtime's entry.
    ai.files2Owners = lib.genAttrs (builtins.attrNames config.ai.${name}.files2) (_: [name]);
  };
}
