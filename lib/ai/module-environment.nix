# The internal, per-runtime channel for process environment a MODULE
# contributes to a harness: `ai.<runtime>.internal._moduleEnvironmentVariables`,
# declared by the shared builder (`lib/ai/app/mkBackendTransform.nix`) and
# merged there UNDER the consumer's `environmentVariables`.
#
# Why a separate channel rather than `ai.<runtime>.environmentVariables`: that
# pool belongs to the consumer. It is their replacement/negation surface, and
# definition provenance treats a package claim there as owned API, so a module
# default written into it would collide with the consumer's own entry instead
# of losing to it.
#
# Why per runtime rather than one root value: a git identity differs per
# harness (name, signing key). A value every harness shares — the sandbox-safe
# `GIT_SSH_COMMAND` — is published to each one.
#
# Only runtimes whose module is imported have the channel. They are found in
# the evaluated OPTION tree, not the first-party registry, because `mkRuntime`
# is public: a downstream runtime gets the shared defaults too. The probe reads
# build-time structure and forces no config, so it cannot recurse into the
# value being defined.
{lib}: let
  runtimeNames = options:
    builtins.filter
    (name: let
      group = options.ai.${name};
    in
      builtins.isAttrs group && !lib.isOption group && group ? internal && lib.isOption group.internal)
    (builtins.attrNames options.ai);
in {
  # `envFor runtime` → attrset of strings. Returns a config fragment.
  publish = options: envFor: {
    ai = lib.genAttrs (runtimeNames options) (runtime: {
      internal._moduleEnvironmentVariables = envFor runtime;
    });
  };
}
