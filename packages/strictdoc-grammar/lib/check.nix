# Runs a value through the NORMALIZED option surface and hands back the merged
# result. This is where the two directions meet: types flow up from strictdoc
# into ./normalized.nix, values flow down from ./dsl.nix, and nothing has
# actually been checked until one is evaluated against the other.
#
# WHY THIS EXISTS AS A STEP. `lib.types.*` are checkers, not functions you can
# apply to a value — the module system is what applies them. So "the DSL cannot
# weaken the types" is only true if something evaluates DSL output against
# `normalized.types`, and this is that something. Skipping it and emitting
# straight from DSL values would leave the entire generated surface inert.
#
# It is also what fills in defaults. `required` is mandatory in the grammar and
# `humanTitle` / `role` / `reverseRole` / `relations` all default to null, so the
# value ./emit.nix receives after this step is total: every optional key is
# present and explicitly null, rather than sometimes absent.
#
# `evalModules` rather than `type.merge` directly: merge wants a loc and a list
# of definitions and gives worse errors, and a one-option module is the same
# check with the module system's own error messages, which name the path.
{
  lib,
  normalized,
  ...
}: let
  # Check `value` against `type`, returning the merged config.
  against = type: value:
    (lib.evalModules {
      modules = [
        {options.value = lib.mkOption {inherit type;};}
        {inherit value;}
      ];
    })
    .config
    .value;

  inherit (normalized) types;
in rec {
  # The whole `[GRAMMAR]` block: `{elements = [ … ];}`.
  grammar = against types.DocumentGrammar;

  # One element, one field, one relation — the same check at a narrower scope,
  # so a fixture can prove a rejection without wrapping it in a whole grammar.
  element = against types.GrammarElement;
  field = against types.GrammarElementField;
  relation = against types.GrammarElementRelation;

  # The element list, checked. The shape callers hand to `emit.grammar`.
  elements = xs: (grammar {elements = xs;}).elements;
}
