# Exact credential registration and client-key model sets, shared by gate and Harness lowering.
{lib}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) placeholderName;
  raw = get (load {dir = ../extracted;}).aggregate "models";
  catalogs = import ./oauth-catalog.nix {inherit lib;} raw;
  providers = import ./providers.nix {inherit lib;};
  render = settings: (import ./default.nix {inherit lib;}).cliproxyapi.render settings;
  # These spellings trigger CPA's auto routing, suffix/prefix stripping or
  # unconditional Claude cloak decoding; exact mode never grants them.
  modelName = name:
    builtins.isString name
    && builtins.match "[!-'*-.0-~]+" name != null
    && name != "auto"
    && !(lib.hasInfix "*" name)
    && !(lib.hasPrefix "claude-fable-5-dd-" name)
    # The service would substitute a whole placeholder with a secret value.
    && placeholderName name == null;
  catalog = credential:
    if credential.apiKey != null
    then credential.apiKey.models
    else catalogs.${credential.oauth.vendor} or [];
  selected = credential:
    lib.unique (
      if credential.models != null
      then credential.models
      else lib.subtractLists (lib.defaultTo [] credential.excludedModels) (catalog credential)
    );
  routedCredentials = instance: client:
    map (route: instance.credentials.${route.credential})
    (lib.filter (route: instance.credentials ? ${route.credential}) client.routes);
  routedModels = instance: client:
    lib.sort builtins.lessThan (lib.unique (lib.concatMap selected (routedCredentials instance client)));
  clientModels = instance: client: let
    served = routedModels instance client;
  in
    if client.models != null
    then lib.intersectLists client.models served
    else lib.subtractLists (lib.defaultTo [] client.excludedModels) served;
  narrow = instance:
    instance
    // {
      credentials = lib.mapAttrs (_: credential:
        credential // lib.optionalAttrs (credential.apiKey != null) {apiKey = credential.apiKey // {models = selected credential;};})
      instance.credentials;
    };
  oauth = instance: lib.filterAttrs (_: credential: credential.oauth != null) instance.credentials;
  # Global vendor filters cannot represent different sets for two named logins.
  exclusions = instance:
    lib.mapAttrs (vendor: credentials:
      lib.subtractLists (selected (lib.head credentials)) (catalogs.${vendor} or []))
    (lib.groupBy (credential: credential.oauth.vendor) (builtins.attrValues (oauth instance)));
  settings = {
    client.codex.optimize-multi-agent-v2 = false;
    multimedia.disable-image-generation = true;
    oauth = {
      model-alias = {};
      providers.antigravity.antigravity-credits = false;
    };
    plugins.enabled = false;
    requests.payload = {};
    routing.force-model-prefix = false;
    upstream.claude = {
      disable-claude-cloak-mode = true;
      disable-cloaking-model-list = true;
    };
  };
  problems = name: instance: let
    path = "ai.cliproxyapi.instances.${name}";
    # Render drops null leaves. Inspect the same document CPA will read.
    clean = builtins.fromJSON (render instance.settings).content;
    generated = builtins.fromJSON (render {api-keys = providers.lower (providers.apiKeys (narrow instance));}).content;
    nonempty = value: !(lib.elem value [null {} [] ""]);
    supported = lib.all (credential: credential.oauth == null || catalogs ? ${credential.oauth.vendor}) (builtins.attrValues instance.credentials);
    vendorSets = lib.groupBy (credential: credential.oauth.vendor) (builtins.attrValues (oauth instance));
  in
    lib.optional instance.fetchModelCatalogs "${path}: exactModels refuses fetchModelCatalogs."
    ++ lib.optional (nonempty (clean.management.secret-key or null)) "${path}: exactModels refuses management.secret-key."
    ++ lib.optional (nonempty (clean.oauth.model-alias or null)) "${path}: exactModels refuses oauth.model-alias."
    ++ lib.optional (nonempty (clean.requests.payload or null)) "${path}: exactModels refuses requests.payload."
    ++ lib.concatMap (key: lib.optional (nonempty (clean.models.${key} or null)) "${path}: exactModels refuses models.${key}.") ["catalog" "codex-catalog" "devin-catalog"]
    ++ lib.optional ((clean.oauth.excluded-models or {}) != exclusions instance) "${path}: exactModels owns oauth.excluded-models; remove conflicting raw exclusions."
    ++ lib.optional ((clean.api-keys or {}) != generated.api-keys) "${path}: exactModels owns api-keys through named upstream credentials; remove raw blocks."
    ++ lib.optional (!supported) "${path}: exactModels supports only claude and codex OAuth vendors."
    ++ lib.concatLists (lib.mapAttrsToList (credentialName: credential: let
      where = "${path}.credentials.${credentialName}";
      catalog =
        if credential.apiKey != null
        then credential.apiKey.models
        else catalogs.${credential.oauth.vendor or ""} or [];
      models = selected credential;
      foldsNames = credential.apiKey != null && lib.any (api: lib.elem providers.apis.${api}.family ["claude" "codex"]) (builtins.attrNames (providers.served credential.apiKey));
      listed = lib.defaultTo [] credential.models ++ lib.defaultTo [] credential.excludedModels ++ lib.optionals (credential.apiKey != null) credential.apiKey.models;
    in
      lib.optional (credential.models == [] || credential.excludedModels == [] || (credential.apiKey != null && credential.apiKey.models == [])) "${where}: model lists must not merge to empty."
      ++ lib.optional (credential.oauth != null && (credential.models != null) == (credential.excludedModels != null)) "${where}: exactModels requires models XOR excludedModels for OAuth."
      ++ lib.optional (credential.apiKey != null && credential.models != null) "${where}: API-key catalogs use apiKey.models."
      ++ lib.optional (!(lib.all modelName listed)) "${where}: exactModels requires exact printable model names without auto, parentheses, slash, wildcard, cloak prefix or secret placeholder."
      ++ lib.optional (!(lib.all (model: lib.elem model catalog) (lib.defaultTo [] credential.models ++ lib.defaultTo [] credential.excludedModels))) "${where}: model selection contains a name outside the vendor catalog."
      ++ lib.optional (foldsNames && lib.length (lib.unique (map lib.toLower models)) != lib.length models) "${where}: CPA's native API-key family collapses case-distinct selected model names."
      ++ lib.optional (models == []) "${where}: model selection must not be empty.")
    instance.credentials)
    ++ lib.concatLists (lib.mapAttrsToList (vendor: credentials:
      lib.optional (lib.length (lib.unique (map (credential: lib.sort builtins.lessThan (selected credential)) credentials)) > 1) "${path}: CPA's OAuth exclusions are vendor-wide; named ${vendor} logins must select the same effective models.")
    vendorSets);
in {
  inherit catalog catalogs clientModels exclusions modelName narrow problems routedCredentials routedModels selected settings;
}
