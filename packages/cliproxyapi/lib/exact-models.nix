# CPA's native registration filters, without client filtering or gate wiring.
{lib}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  raw = get (load {dir = ../extracted;}).aggregate "models";
  ids = vendor: let
    rows = raw.${vendor};
  in
    if !builtins.isList rows || rows == [] || !(lib.all (row: builtins.isAttrs row && builtins.isString (row.id or null)) rows)
    then throw "CPA embedded models catalog changed shape"
    else map (row: row.id) rows;
  catalogs = {
    claude = ids "claude";
    codex = lib.unique (lib.concatMap ids ["codex-free" "codex-plus" "codex-pro" "codex-team"]);
  };
  # These spellings trigger CPA's auto routing, suffix/prefix stripping or
  # unconditional Claude cloak decoding; exact mode never grants them.
  modelName = name:
    builtins.isString name
    && builtins.match "[!-'*-.0-~]+" name != null
    && name != "auto"
    && !(lib.hasInfix "*" name)
    && !(lib.hasPrefix "claude-fable-5-dd-" name);
  selected = credential: let
    catalog =
      if credential.apiKey != null
      then credential.apiKey.models
      else catalogs.${credential.oauth.vendor} or [];
  in
    lib.sort builtins.lessThan (lib.unique (
      if credential.models != null
      then credential.models
      else lib.subtractLists (lib.defaultTo [] credential.excludedModels) catalog
    ));
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
    clean = builtins.fromJSON ((import ./default.nix {inherit lib;}).cliproxyapi.render instance.settings).content;
    nonempty = value: !(lib.elem value [null {} [] ""]);
    forbidden = where: value:
      if builtins.isList value
      then lib.concatMap (forbidden where) value
      else if !builtins.isAttrs value
      then []
      else
        lib.concatLists (lib.mapAttrsToList (key: child:
          lib.optional (lib.elem key ["alias" "cloak" "prefix"]) "${path}.settings.${where}: exactModels refuses ${key}."
          ++ forbidden where child)
        value);
    supported = lib.all (credential: credential.oauth == null || catalogs ? ${credential.oauth.vendor}) (builtins.attrValues instance.credentials);
    vendorSets = lib.groupBy (credential: credential.oauth.vendor) (builtins.attrValues (oauth instance));
  in
    lib.optional instance.fetchModelCatalogs "${path}: exactModels refuses fetchModelCatalogs."
    ++ lib.optional (nonempty (clean.management.secret-key or null)) "${path}: exactModels refuses management.secret-key."
    ++ lib.optional (nonempty (clean.oauth.model-alias or null)) "${path}: exactModels refuses oauth.model-alias."
    ++ lib.optional (nonempty (clean.requests.payload or null)) "${path}: exactModels refuses requests.payload."
    ++ lib.concatMap (key: lib.optional (nonempty (clean.models.${key} or null)) "${path}: exactModels refuses models.${key}.") ["catalog" "codex-catalog" "devin-catalog"]
    ++ lib.concatLists (lib.mapAttrsToList (family: blocks:
      lib.optional (!(lib.elem family ["claude" "codex" "openai-compatibility"]) && nonempty blocks) "${path}: exactModels refuses unaudited API-key vendor."
      ++ forbidden "api-keys.${family}" blocks) (clean.api-keys or {}))
    ++ lib.optional (!supported) "${path}: exactModels supports only claude and codex OAuth vendors."
    ++ lib.concatLists (lib.mapAttrsToList (credentialName: credential: let
      where = "${path}.credentials.${credentialName}";
      catalog =
        if credential.apiKey != null
        then credential.apiKey.models
        else catalogs.${credential.oauth.vendor or ""} or [];
      listed = lib.defaultTo [] credential.models ++ lib.defaultTo [] credential.excludedModels ++ lib.optionals (credential.apiKey != null) credential.apiKey.models;
    in
      lib.optional (credential.models == [] || credential.excludedModels == [] || (credential.apiKey != null && credential.apiKey.models == [])) "${where}: model lists must not merge to empty."
      ++ lib.optional (credential.oauth != null && (credential.models != null) == (credential.excludedModels != null)) "${where}: exactModels requires models XOR excludedModels for OAuth."
      ++ lib.optional (credential.apiKey != null && credential.models != null) "${where}: API-key catalogs use apiKey.models."
      ++ lib.optional (!(lib.all modelName listed)) "${where}: exactModels requires exact printable model names without auto, parentheses, slash, wildcard or cloak prefix."
      ++ lib.optional (!(lib.all (model: lib.elem model catalog) (lib.defaultTo [] credential.models ++ lib.defaultTo [] credential.excludedModels))) "${where}: model selection contains a name outside the vendor catalog."
      ++ lib.optional (selected credential == []) "${where}: model selection must not be empty.")
    instance.credentials)
    ++ lib.concatLists (lib.mapAttrsToList (vendor: credentials:
      lib.optional (lib.length (lib.unique (map selected credentials)) > 1) "${path}: CPA's OAuth exclusions are vendor-wide; named ${vendor} logins must select the same effective models.")
    vendorSets);
in {
  inherit catalogs exclusions modelName problems selected settings;
  narrow = instance:
    instance
    // {
      credentials = lib.mapAttrs (_: credential:
        credential // lib.optionalAttrs (credential.apiKey != null) {apiKey = credential.apiKey // {models = selected credential;};})
      instance.credentials;
    };
}
