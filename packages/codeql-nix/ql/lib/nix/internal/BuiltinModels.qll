/** Versioned opaque builtin identities; lexical scope resolution belongs to N1. */
private import nix.internal.generated.Builtins as Model

predicate builtinIdentity(string namespace, string name, string identity) {
  exists(string version |
    Model::modelFingerprint(version) and nx_runs(_, _, _, _, version, _) and
    Model::identity(namespace, name, identity)
  )
}

predicate runtimeIdentity(string identity) { Model::runtimeIdentity(identity) }

predicate runtimeSourceHash(string hash) { Model::runtimeSourceHash(hash) }

predicate modelFingerprint(string version) { Model::modelFingerprint(version) }

predicate supportsRuntime(string identity, string sourceHash) {
  runtimeIdentity(identity) and runtimeSourceHash(sourceHash)
}
