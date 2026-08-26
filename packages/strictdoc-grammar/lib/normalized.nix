# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Written by packages/strictdoc-grammar/extract/normalize.py from ./faithful.nix.
#
# NORMALIZED is faithful with specific nodes replaced — deep-merge in spirit.
# Every converter is a PAIR: a type rewrite (faithful type -> normalized type)
# and an encoder (normalized value -> faithful value, on the way to the file).
# `IS_COMPOSITE` is `strMatching "(True|False)"` faithfully and `types.bool`
# normalized, so its encoder is `b: if b then "True" else "False"`.
#
# Encode only. There is no decoder; reading `.sgra` back into Nix is out of
# scope.
#
# An unrecognized shape is an ERROR, not a fallback to free text — declaring a
# value unconstrained is itself a named converter, so "we decided this is free
# text" stays distinguishable from "nobody classified this".
#
# SCAFFOLD PLACEHOLDER — this is the shape with no content. The first real
# normalization overwrites the whole file.
#
# Eventual signature: `{lib, faithful}:`. `_:` here so the placeholder
# ignores the arguments the barrel passes without tripping deadnix.
_: {
  # The normalized option surface — faithful's entries with converters applied.
  types = {};

  # normalized value -> faithful value, keyed the same way as `types`.
  encoders = {};

  # Which named converter fired on which faithful node. Kept so a
  # classification is auditable rather than inferred from the result.
  converters = {};

  meta = {
    generated = false;
  };
}
