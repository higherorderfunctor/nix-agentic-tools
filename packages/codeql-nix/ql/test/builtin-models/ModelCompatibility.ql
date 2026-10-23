/** Exact compatibility, absent invented exports, and distinct primitive identities. */
import nix.internal.BuiltinModels

select
  count(string runtime, string hash |
    runtimeIdentity(runtime) and runtimeSourceHash(hash) and supportsRuntime(runtime, hash)
  | runtime),
  count(string runtime, string hash |
    runtimeIdentity(runtime) and runtimeSourceHash(hash) and
    (supportsRuntime(runtime + "-mismatch", hash) or supportsRuntime(runtime, hash + "-mismatch"))
  | runtime),
  count(string identity | builtinIdentity("builtins", "m3DefinitelyNotABuiltin", identity) | identity),
  count(string name, string identity |
    name = ["import", "map", "toString"] and builtinIdentity("builtins", name, identity)
  | identity)
