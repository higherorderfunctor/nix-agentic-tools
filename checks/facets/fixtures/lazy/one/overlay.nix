# An ordinary leaf beside a package that throws when evaluated: validating
# this overlay must not force the package.
_context: {
  claims = [["ai" "ordinary"]];
  overlay = _final: prev: {
    ai = prev.ai // {ordinary = "ordinary";};
  };
}
