/** Versioned opaque builtin identities; lexical scope resolution belongs to N1. */
private import nix.internal.generated.Builtins as Model
private import nix.internal.generated.Modules as Bundle

predicate builtinIdentity(string namespace, string name, string identity) {
  exists(string version |
    Model::modelFingerprint(version) and Bundle::builtinFingerprint(version) and
    exists(string bundle | Bundle::bundleFingerprint(bundle) and nx_runs(_, _, _, _, bundle, _)) and
    Model::identity(namespace, name, identity)
  )
}

predicate runtimeIdentity(string identity) { Model::runtimeIdentity(identity) }

predicate runtimeSourceHash(string hash) { Model::runtimeSourceHash(hash) }

predicate modelFingerprint(string version) { Model::modelFingerprint(version) }

predicate supportsRuntime(string identity, string sourceHash) {
  runtimeIdentity(identity) and runtimeSourceHash(sourceHash)
}

/** Recognized globals remain reserved when the run cannot authenticate their model. */
predicate globalBindingIdentity(string name, string identity) {
  Model::identity("", name, identity)
}
