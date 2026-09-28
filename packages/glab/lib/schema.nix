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

  # Keys the schema marks `Keyring: true` get a secret OPTION. The flag
  # says where glab STORES a value, not whether the value is sensitive, so
  # it picks which keys get a typed file-or-helper reference and nothing
  # more (`refresh_token` is a token with `Keyring: false`; see the
  # extraSettings reservation below). The set is DERIVED rather than
  # listed. No secret option accepts a literal, because a literal would
  # land in the world-readable Nix store.
  #
  # Every other user-settable key that is not a token key — `host`
  # included — is an ordinary setting below.
  secretKeys =
    builtins.filter (n: byName.${n}.keyring) (builtins.attrNames byName);

  # A token key is a secret key, or any key named `token` or `*_token`,
  # compared case-insensitively. The keyring flag alone misses
  # `refresh_token` (REFRESH_TOKEN), which upstream stores outside the
  # keyring and marks not user-settable. The name rule also covers token
  # keys a later upstream adds: `isTokenName` is applied to extraSettings
  # keys directly, so a token key newer than this schema is rejected too.
  isTokenName = n: let
    u = lib.toUpper n;
  in
    u == "TOKEN" || lib.hasSuffix "_TOKEN" u;

  tokenKeys =
    lib.unique
    (secretKeys ++ builtins.filter isTokenName (builtins.attrNames byName));

  # Everything else the user may set. A token key is never a setting, so a
  # later upstream `*_token` key outside the keyring does not become a
  # literal option.
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
      && !(builtins.elem n tokenKeys))
    (builtins.attrNames byName);

  # First env var wins. `EnvKeyEquivalence` returns them in resolution
  # order and glab takes the first non-empty one, so writing the first is
  # the only spelling that cannot be shadowed by a later alias that
  # happens to already be in the environment.
  envVarOf = key: builtins.head byName.${key}.envVars;

  # ── extraSettings must not name a secret ──────────────────────────
  # The wrapper exports every extraSettings key upper-cased, as a literal,
  # from a script in the Nix store. Left open, that is a second way to put
  # a token in the store: `extraSettings.gitlab_token` exports GITLAB_TOKEN,
  # overrides a configured `token.file` (extraSettings are exported last),
  # and brings the token export back under `keyringSync.enable`, which
  # removes it on purpose.
  #
  # So every token key AND every env var glab reads one from is reserved,
  # compared upper-cased. Matching env var names matters, not only key
  # names: `gitlab_token` is not itself a key.
  #
  # "Every env var" includes the CI auto-login ones (`ciEnvVars`). With
  # GLAB_ENABLE_CI_AUTOLOGIN and GITLAB_CI both "true", glab reads
  # `job_token` from CI_JOB_TOKEN instead of JOB_TOKEN, and
  # `glab ci run-trig` reads CI_JOB_TOKEN unconditionally. `envVars` alone
  # never names it.
  #
  # A key named like a token (`isTokenName`) is rejected even when this
  # schema does not know it.

  reservedExtraSettingNames =
    map lib.toUpper
    (tokenKeys
      ++ builtins.concatMap (k: byName.${k}.envVars ++ byName.${k}.ciEnvVars) tokenKeys);

  # Where a secret goes instead, for both errors below.
  secretHint = "Set ${lib.concatMapStringsSep ", " (k: "glab.${k}") secretKeys} to a `file` or `helper` reference instead.";

  # Identity on an allowed attrset; otherwise throws naming the offending
  # KEYS and never their values. Shared by the option's `apply` and by
  # mkGlab, so the module and the public `lib.glab.mkGlab` reject the same
  # keys with the same message.
  checkExtraSettings = extraSettings: let
    reserved =
      builtins.filter
      (n: isTokenName n || builtins.elem (lib.toUpper n) reservedExtraSettingNames)
      (builtins.attrNames extraSettings);
  in
    if reserved == []
    then extraSettings
    else
      throw ''
        glab.extraSettings: ${lib.concatStringsSep ", " reserved} would export a glab secret as a literal, which lands in the world-readable Nix store. ${secretHint}'';

  # The same guard for `settings`. The module's submodule declares only
  # `settingKeys`, but the public `lib.glab.mkGlab` takes an untyped cfg
  # and exports every `settings` attr under its key's env var — so
  # `settings.token` would write GITLAB_TOKEN into the store. Identity when
  # every key is a setting key; otherwise throws naming the KEYS only.
  checkSettings = settings: let
    invalid =
      builtins.filter
      (n: !(builtins.elem n settingKeys))
      (builtins.attrNames settings);
  in
    if invalid == []
    then settings
    else
      throw ''
        glab.settings: ${lib.concatStringsSep ", " invalid} is a secret or not a glab setting key, and settings are exported as literals in the world-readable Nix store. ${secretHint} A non-secret key newer than the packaged glab goes in glab.extraSettings.'';
in {
  inherit
    byName
    checkExtraSettings
    checkSettings
    envVarOf
    secretKeys
    settingKeys
    ;
}
