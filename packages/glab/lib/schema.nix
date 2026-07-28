# The committed glab config-key schema, partitioned once.
#
# Imported by BOTH ../modules/options.nix (which declares an option per
# key) and ./mkGlab.nix (which renders an export per set key). They must
# agree on which keys are secrets and which are plain settings, and on
# which env var each maps to — a second copy of that partitioning is how
# they stop agreeing. The first draft did duplicate it and immediately
# grew a bug: the wrapper emitted `GITLAB_HOST` twice, because its
# secret-key list was built from a different expression than the options'.
#
# Reads the COMMITTED sidecar (`overlays/generic/glab-extracted.json`),
# not `passthru.extracted`. Reading the derivation would be
# import-from-derivation on every module evaluation; the sidecar is kept
# honest by `checks.glab-extracted` instead.
{lib}: let
  schema =
    builtins.fromJSON
    (builtins.readFile ../../../overlays/generic/glab-extracted.json);

  byName = builtins.listToAttrs (map (k: {
      inherit (k) name;
      value = k;
    })
    schema);

  # Keys the schema itself marks as credentials (`Keyring: true`), plus
  # `host`. The keyring flag is upstream's own answer to "is this
  # sensitive", so the secret-capable set is DERIVED rather than listed.
  #
  # `host` is added on top because a self-hosted instance URL can itself
  # be something an operator would rather not publish in a world-readable
  # store path, even though upstream does not class it as a credential.
  # Its `plain` branch covers the ordinary public case.
  #
  # `unique` is load-bearing: `host` is also a member of `byName`, and
  # without it a future upstream that flips `host` to keyring-eligible
  # would silently emit its export twice.
  secretKeys =
    lib.unique
    (["host"] ++ builtins.filter (n: byName.${n}.keyring) (builtins.attrNames byName));

  # Everything else the user may set.
  #
  # List-typed keys are excluded: the only one today is `custom_headers`,
  # whose value is a sequence of {name, value} records with no meaningful
  # single-env-var spelling. Configure it with `glab config set`.
  settingKeys =
    builtins.filter
    (n: let
      k = byName.${n};
    in
      k.userSettable
      && k.type != "list"
      && !(builtins.elem n secretKeys))
    (builtins.attrNames byName);

  # First env var wins. `EnvKeyEquivalence` returns them in resolution
  # order and glab takes the first non-empty one, so writing the first is
  # the only spelling that cannot be shadowed by a later alias that
  # happens to already be in the environment.
  envVarOf = key: builtins.head byName.${key}.envVars;
in {
  inherit
    byName
    envVarOf
    secretKeys
    settingKeys
    ;
}
