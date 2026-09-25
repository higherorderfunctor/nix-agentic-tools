# An ordinary leaf beside a package that throws when evaluated: validating
# this overlay must not force the package. `callable` is a function leaf, which
# `==` never finds equal to itself; the later owner `two` must still validate.
_context: {
  claims = [["ai" "callable"] ["ai" "ordinary"]];
  overlay = _final: prev: {
    ai =
      prev.ai
      // {
        callable = value: value;
        ordinary = "ordinary";
      };
  };
}
