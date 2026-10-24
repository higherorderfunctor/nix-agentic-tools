# `ai.cliproxyapi.instances.<name>`: CLIProxyAPI daemons, the same on both
# backends apart from the default state root. The config is rendered at each
# start from the typed settings; CLIProxyAPI's own rewrites of it (the hashed
# management key, management API saves) reach only that copy. Its auth
# directory holds the OAuth logins it writes, so it lives in `stateDir`.
# CLIProxyAPI fetches its model catalogs and its management panel from the
# network unprompted; both default off here (see docs/cliproxyapi-settings.md).
#
# Named upstream credentials and client keys belong to the Instance.
backend: {
  config,
  lib,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
  providersLib = cliproxyapi.providers;
  # A named client key also written by hand could widen its allowlist rules.
  handWritten = name: instance: let
    clients = lib.mapAttrsToList (clientName: client: client // {option = "ai.cliproxyapi.instances.${name}.clientKeys.${clientName}";}) instance.clientKeys;
    access = instance.settings.access or null;
    listed = field: lib.filter (value: value != null) (lib.defaultTo [] (access.${field} or null));
    keys = listed "api-keys";
    entries = map (entry: entry.api-key) (listed "key-allowlist");
    extra = list: client: lib.count (key: key == client.key) list > lib.count (other: other.key == client.key) clients;
    path = "ai.cliproxyapi.instances.${name}.settings.access";
  in
    lib.concatMap (client:
      lib.optional (extra keys client)
      "${path}.api-keys lists ${client.option}.key by hand; ${client.option} adds it to this instance. Remove the hand-written entry."
      ++ lib.optional (extra entries client)
      "${path}.key-allowlist has a hand-written entry for ${client.option}.key, whose routes ${client.option}.routes sets. Remove the hand-written entry.")
    clients;
  # Go trims every Unicode space before comparing URLs. Printable edges make
  # that trim a no-op for hand-written blocks sharing a provider's family.
  printable = text: text != "" && builtins.match "[!-~]" text != null;
  edgesPrintable = url: url == "" || (printable (builtins.substring 0 1 url) && printable (builtins.substring (builtins.stringLength url - 1) 1 url));
  baseUrlOf = block: lib.defaultTo "" (block.base-url or null);
  sharedBaseUrls = name: instance: let
    served = definition: builtins.attrNames (providersLib.served definition);
    families = lib.unique (lib.concatMap (definition: map (api: providersLib.apis.${api}.family) (served definition)) (builtins.attrValues (providersLib.apiKeys instance)));
    blocksOf = family: lib.defaultTo [] (instance.settings.api-keys.${family} or null);
  in
    lib.concatMap (family:
      map (block: "ai.cliproxyapi.instances.${name}.settings.api-keys.${family}: the block with base-url ${builtins.toJSON (baseUrlOf block)} starts or ends with a character other than printable ASCII (a space, a non-ASCII character or a control character). CPA trims every Unicode space (no-break space, form feed, vertical tab, ...) before comparing base URLs, which Nix cannot reproduce, so a provider's rule could reach this block. Write the URL without them.")
      (lib.filter (block: !(edgesPrintable (baseUrlOf block))) (blocksOf family)))
    families
    ++ lib.concatLists (lib.mapAttrsToList (provider: definition:
      lib.concatMap (api: let
        inherit (providersLib.apis.${api}) family;
        url = definition.apis.${api}.base-url;
      in
        lib.optional (lib.count (block: baseUrlOf block == url) (blocksOf family) > 1)
        "ai.cliproxyapi.instances.${name}.credentials.${provider}.apiKey.apis.${api}.base-url `${url}` is also the base URL of another settings.api-keys.${family} block, which the provider's allowlist rule would reach too. Give each block its own base URL.")
      (served definition))
    (providersLib.apiKeys instance))
    # API-key names become CPA compatibility provider identities.
    ++ map (provider: "ai.cliproxyapi.instances.${name}.credentials.${provider}: an API-key credential name must be letters, digits, `.`, `_` and `-`, starting with a letter or digit.")
    (builtins.filter (provider: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" provider == null) (builtins.attrNames (providersLib.apiKeys instance)));
  # CPA's ParseSuffix (internal/thinking/suffix.go:23-44): a model name may
  # end in a "(...)" thinking suffix, and the name without it routes too. When
  # it does, drop everything from the last "(".
  parseSuffix = model: let
    groups = builtins.match "(.*)\\(.*\\)" model;
  in
    if groups == null
    then model
    else builtins.head groups;
  # CPA keeps only the first model per case-insensitive client-visible name
  # and drops the rest (sdk/cliproxy/service_models.go:924-929). An aliased
  # entry also claims routing keys, and a claim that shadows another entry's
  # listed name sends its requests to the wrong upstream model, so every
  # listed name is resolved the way the served family resolves it and a name
  # reaching another entry's upstream model is refused:
  #
  # - claude and codex credentials (the anthropic and responses APIs) resolve
  #   through a table built from aliased entries only, first claim per lowered
  #   key, each entry claiming alias, ParseSuffix(alias), name and
  #   ParseSuffix(name); a lookup tries the requested key, then the key
  #   without its suffix, and puts the suffix back on the resolved name
  #   (sdk/cliproxy/auth/conductor_models.go:20-46, 676-696;
  #   sdk/cliproxy/auth/oauth_model_alias.go:122-135).
  # - openai-compatibility credentials (the chat API) resolve through a pool
  #   that tries every entry's alias, the requested name and its
  #   suffix-stripped base alike, before any name
  #   (sdk/cliproxy/auth/conductor_models.go:132-158;
  #   sdk/cliproxy/auth/oauth_model_alias.go:139-193).
  duplicateModels = name: instance:
    lib.concatLists (lib.mapAttrsToList (credential: apiKey: let
      visible = map lib.toLower (providersLib.visibleModels apiKey);
      servedApis = builtins.attrNames (providersLib.served apiKey);
      # Each entry's listed name (alias when set, else name) and the upstream
      # name a request for it must reach.
      listed =
        map (model: {
          inherit (model) name;
          visible =
            if model.alias != null
            then model.alias
            else model.name;
        })
        apiKey.models;
      # preserveResolvedModelSuffix: the request's suffix comes back on a
      # resolved name that lacks one.
      rawSuffix = model: let
        groups = builtins.match ".*\\((.*)\\)" model;
      in
        if groups == null
        then null
        else builtins.head groups;
      withSuffix = requested: resolved: let
        suffix = rawSuffix requested;
      in
        if parseSuffix resolved != resolved
        then resolved
        else if suffix != null && suffix != ""
        then resolved + "(" + suffix + ")"
        else resolved;
      # compileAPIKeyModelAliasForModels: aliased entries in order, each
      # claiming four lowered keys, first claim wins, empty keys skipped.
      table =
        lib.foldl'
        (claimed: entry: let
          alias = lib.toLower entry.alias;
          keys = lib.unique [
            alias
            (parseSuffix alias)
            (lib.toLower entry.name)
            (lib.toLower (parseSuffix entry.name))
          ];
          fresh = lib.filter (key: key != "" && !(claimed ? ${key})) keys;
        in
          claimed // builtins.listToAttrs (map (key: lib.nameValuePair key entry.name) fresh))
        {}
        (lib.filter (model: model.alias != null) apiKey.models);
      # lookupAPIKeyUpstreamModel: the exact lowered key, then the key without
      # its suffix.
      resolveTable = model: let
        key = lib.toLower model;
        base = parseSuffix key;
        hit =
          table.${
            key
          } or (
            if base != "" && base != key
            then table.${base} or null
            else null
          );
      in
        if hit == null
        then null
        else withSuffix model hit;
      # resolveModelAliasPoolFromConfigModels: for each lookup candidate in
      # turn (the name, then its suffix-stripped base), the first entry whose
      # alias matches resolves to its name; when no alias matched, the first
      # entry whose name matches does.
      resolvePool = model: let
        base = parseSuffix model;
        candidates =
          if base == "" || base == model
          then [model]
          else [model base];
        aliasMatch = candidate:
          lib.findFirst (entry: entry.alias != null && lib.toLower entry.alias == lib.toLower candidate) null apiKey.models;
        nameMatch = candidate:
          lib.findFirst (entry: lib.toLower entry.name == lib.toLower candidate) null apiKey.models;
        aliasHit = lib.findFirst (candidate: aliasMatch candidate != null) null candidates;
        nameHit = lib.findFirst (candidate: nameMatch candidate != null) null candidates;
        entry =
          if aliasHit != null
          then aliasMatch aliasHit
          else if nameHit != null
          then nameMatch nameHit
          else null;
      in
        if entry == null
        then null
        else withSuffix model entry.name;
      # A listed name misroutes when CPA resolves it to another entry's
      # upstream name.
      misrouting = resolve: entry: let
        result = resolve entry.visible;
        expected = withSuffix entry.visible entry.name;
      in
        lib.optional (result != null && result != expected)
        "ai.cliproxyapi.instances.${name}.credentials.${credential}.apiKey.models: a request for `${entry.visible}` is sent upstream as `${result}`, not `${expected}`; another entry's routing claim wins. Give each entry a client-visible name that resolves to its own upstream name.";
      usesTable = lib.any (api: api == "anthropic" || api == "responses") servedApis;
      usesPool = lib.elem "chat" servedApis;
    in
      map (model: "ai.cliproxyapi.instances.${name}.credentials.${credential}.apiKey.models lists `${model}` to clients more than once; CPA compares these names case-insensitively and keeps only the first. Give each entry a distinct client-visible name (alias when set, else name).")
      (lib.unique (lib.filter (model: lib.count (other: other == model) visible > 1) visible))
      ++ lib.optionals usesTable (lib.concatMap (misrouting resolveTable) listed)
      ++ lib.optionals usesPool (lib.concatMap (misrouting resolvePool) listed))
    (providersLib.apiKeys instance));
in {
  imports = [
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      # `--local-model` is the only switch for the model catalog fetches: it
      # selects the embedded catalogs, and no setting selects the embedded catalogs.
      arguments = instance:
        ''--config "$CPA_CONFIG"''
        + lib.optionalString (!instance.fetchModelCatalogs) " --local-model";
      inherit backend;
      defaultPort = 8317;
      derived = {instance, ...}: {
        api-keys = lib.mkIf ((providersLib.apiKeys instance) != {}) (providersLib.lower (providersLib.apiKeys instance));
        access = lib.mkIf (instance.clientKeys != {}) {
          api-keys = map (client: client.key) (builtins.attrValues instance.clientKeys);
          key-allowlist =
            lib.mapAttrsToList (clientName: client: {
              api-key = client.key;
              credentials = lib.concatMap (choice: lib.toList ((providersLib.route instance "clientKeys.${clientName}.routes" choice).rule or [])) client.routes;
            })
            instance.clientKeys;
        };
        # Without this the daemon downloads its control panel from GitHub at
        # start and every 3 hours after.
        management.disable-auto-update-panel = lib.mkDefault true;
        oauth.auth-dir = "${instance.stateDir}/auth";
        server = {
          host = lib.mkDefault "127.0.0.1";
          inherit (instance) port;
        };
      };
      directories = instance: ["${instance.stateDir}/auth"];
      extraOptions = {
        clientKeys = lib.mkOption {
          type = lib.types.attrsOf providersLib.clientKeyType;
          default = {};
          description = "Named client keys, each with a redact key and ordered routes to named upstream credentials.";
        };
        credentials = lib.mkOption {
          type = lib.types.attrsOf providersLib.credentialType;
          default = {};
          description = "Declare each upstream credential once by name, as OAuth or API key.";
        };
        fetchModelCatalogs = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether the daemon fetches its model catalogs from
            raw.githubusercontent.com and models.router-for.me at start and every
            3 hours. Off, it runs with `--local-model` and serves the catalogs
            embedded in the package; a `settings.models.*` source still takes
            precedence.
          '';
        };
      };
      owner = "cliproxyapi";
      packagePath = "generic.cliproxyapi";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.cliproxyapi";
      inherit (cliproxyapi) render settingsType;
      tool = "CLIProxyAPI";
      variable = "CPA_CONFIG";
    })
  ];

  # Plugin executors choose credentials outside access.key-allowlist, and the
  # plugin host hands any plugin every auth file through host.auth.get, so
  # enabling plugins voids the allowlist (docs/cliproxyapi-key-allowlist.md).
  # A rule with kind = "oauth" and base-urls can never match: base-urls compare
  # an API-key credential's base_url and an OAuth login is never matched by one.
  # The ids and base-urls types check definitions, so a list whose elements all
  # sit under a false mkIf passes them and merges to [], which CPA reads as
  # unrestricted; the assertion checks the merged value. The same holds for
  # null entries in the allowlist itself: the renderer drops them, so a list of
  # only nulls renders as [], which switches enforcement off for every key. No
  # type refines that list, since the generator refuses a refinement row on a
  # node with a secret descendant (the entry's api-key), so the assertion
  # refuses any null entry.
  config.assertions =
    lib.concatLists (lib.mapAttrsToList (name: instance: let
      setting = path: lib.attrByPath path null instance.settings;
      present = lib.filter (item: item != null);
      allowlist = lib.defaultTo [] (setting ["access" "key-allowlist"]);
      entries = present allowlist;
      credentialsOf = entry: present (lib.defaultTo [] entry.credentials);
      rules = lib.concatMap credentialsOf entries;
      emptied = field: lib.filter (rule: rule.${field} == []) rules;
      unmatchable = entry: lib.filter (rule: rule.kind == "oauth" && lib.defaultTo [] rule."base-urls" != []) (credentialsOf entry);
      refusal = where: "${where} has a rule with kind = \"oauth\" and base-urls, which can never match: base-urls compare an API-key credential's base URL and never match an OAuth login. Use kind = \"apikey\" or drop base-urls.";
      offending = lib.filter (entry: unmatchable entry != []) entries;
    in
      lib.optionals instance.enable ([
          {
            assertion = setting ["plugins" "enabled"] != true || lib.elem (setting ["access" "key-allowlist"]) [null []];
            message = "ai.cliproxyapi.instances.${name}: settings.plugins.enabled = true voids settings.access.key-allowlist: plugin executors choose credentials outside it and can read every credential through host.auth.get. Disable plugins or drop the allowlist.";
          }
          {
            assertion = !(lib.elem null allowlist);
            message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist has a null entry, which the renderer drops: a list of only nulls renders as [] and switches enforcement off for every key. Remove the null entry, or set the list to [] to switch the allowlist off.";
          }
          {
            assertion = offending == [];
            message = "ai.cliproxyapi.instances.${name}: ${refusal "settings.access.key-allowlist"}";
          }
          {
            assertion = lib.all (rule: !(lib.elem null (lib.defaultTo [] rule.accounts))) rules;
            message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist[].credentials[].accounts contains null, which the renderer drops and could remove the account restriction. List account references only.";
          }
        ]
        ++ map (field: {
          assertion = emptied field == [];
          message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist[].credentials[].${field} merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value.";
        }) ["accounts" "base-urls" "ids"]
        ++ lib.mapAttrsToList (credentialName: credential: {
          assertion = (credential.oauth != null) != (credential.apiKey != null);
          message = "ai.cliproxyapi.instances.${name}.credentials.${credentialName}: declare exactly one of oauth or apiKey.";
        })
        instance.credentials
        ++ lib.concatLists (lib.mapAttrsToList (clientName: client:
          map (choice: let
            result = providersLib.route instance "ai.cliproxyapi.instances.${name}.clientKeys.${clientName}.routes" choice;
          in {
            assertion = !(result ? problem);
            message = result.problem or "";
          })
          client.routes)
        instance.clientKeys)))
    config.ai.cliproxyapi.instances)
    ++ map (message: {
      assertion = false;
      inherit message;
    }) (lib.concatLists (lib.mapAttrsToList handWritten config.ai.cliproxyapi.instances
      ++ lib.mapAttrsToList sharedBaseUrls config.ai.cliproxyapi.instances
      ++ lib.mapAttrsToList duplicateModels config.ai.cliproxyapi.instances));
}
