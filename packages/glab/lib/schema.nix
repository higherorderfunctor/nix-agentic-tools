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
# Reads the COMMITTED sidecar (`packages/glab/extracted.json`),
# not `passthru.extracted`. Reading the derivation would be
# import-from-derivation on every module evaluation; the sidecar is kept
# honest by `checks.glab-extracted` instead.
{lib}: let
  schema =
    builtins.fromJSON
    (builtins.readFile ../extracted.json);

  byName = builtins.listToAttrs (map (k: {
      inherit (k) name;
      value = k;
    })
    schema);

  rv = import ../../../lib/runtime-values {inherit lib;};
  secretKeys = builtins.filter (name:
    rv.classify {
      path = [name];
      hints = byName.${name};
    }
    == "secret") (builtins.attrNames byName);
  topLevelKeys = lib.unique (["host"] ++ secretKeys);

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
      && !(builtins.elem n topLevelKeys))
    (builtins.attrNames byName);

  # First env var wins. `EnvKeyEquivalence` returns them in resolution
  # order and glab takes the first non-empty one, so writing the first is
  # the only spelling that cannot be shadowed by a later alias that
  # happens to already be in the environment.
  envVarOf = key: builtins.head byName.${key}.envVars;
  # Include every schema-classified credential alias, even a token such as
  # refresh_token that upstream does not mark as keyring-backed. glab also
  # accepts CI_JOB_TOKEN outside its config-key schema.
  tokenEnvVars = ["CI_JOB_TOKEN"] ++ lib.concatMap (name: byName.${name}.envVars) secretKeys;
in {
  inherit
    byName
    envVarOf
    secretKeys
    settingKeys
    tokenEnvVars
    topLevelKeys
    ;
}
