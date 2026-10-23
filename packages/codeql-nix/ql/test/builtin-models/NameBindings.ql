/** M3's named builtin-identity part; lexical resolution belongs to N1. */
import nix.internal.BuiltinModels

from string name, string identity
where
  name = ["import", "map", "toString"] and
  builtinIdentity("", name, identity) and
  builtinIdentity("builtins", name, identity)
select name, "global-namespace-alias"
