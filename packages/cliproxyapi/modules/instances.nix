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
  instancesLib = import ../../ai-module/lib/instances.nix {inherit lib;};
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
  # Every instance is a selectable proxy (lib/ai/proxy); a selected client
  # carries its key and its routed credentials, with declared API-key models,
  # in route order. The claim keeps the name unique across proxy owners.
  proxyInstances =
    lib.mapAttrs (_: instance: {
      backend = "cliproxyapi";
      clients =
        lib.mapAttrs (_: client: {
          inherit (client) key;
          credentials = map (route: {
            name = route.credential;
            models = instance.credentials.${route.credential}.apiKey.models or [];
          }) (builtins.filter (route: builtins.hasAttr route.credential instance.credentials) client.routes);
        })
        instance.clientKeys;
      inherit (instance) enable;
      url = instancesLib.origin instance;
    })
    config.ai.cliproxyapi.instances;
in {
  imports = [
    (instancesLib.module {
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

  config = {
    ai = {
      cliproxyapi.claims.proxy-instance = builtins.attrNames config.ai.cliproxyapi.instances;
      internal = {inherit proxyInstances;};
    };

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
    assertions =
      lib.concatLists (lib.mapAttrsToList (name: instance: let
        setting = path: lib.attrByPath path null instance.settings;
        present = lib.filter (item: item != null);
        allowlist = lib.defaultTo [] (setting ["access" "key-allowlist"]);
        entries = present allowlist;
        credentialsOf = entry: present (lib.defaultTo [] entry.credentials);
        rules = lib.concatMap credentialsOf entries;
        aliasMaps =
          map (block: lib.filterAttrs (_: value: value != null) (lib.defaultTo {} (block.tool-aliases or null)))
          (lib.concatMap (block: [block] ++ present (lib.defaultTo [] (block.keys or null))) (present (lib.defaultTo [] (setting ["api-keys" "claude"]))));
        validAliases = aliases: let
          sources = builtins.attrNames aliases;
          targets = builtins.attrValues aliases;
        in
          lib.all (name: builtins.match "[A-Za-z0-9_-]{1,64}" name != null) (sources ++ targets)
          && lib.length targets == lib.length (lib.unique targets)
          && lib.all (source: source == aliases.${source} || !(builtins.hasAttr aliases.${source} aliases)) sources;
        emptied = field: lib.filter (rule: rule.${field} == []) rules;
        unmatchable = entry: lib.filter (rule: rule.kind == "oauth" && lib.defaultTo [] rule."base-urls" != []) (credentialsOf entry);
        refusal = where: "${where} has a rule with kind = \"oauth\" and base-urls, which can never match: base-urls compare an API-key credential's base URL and never match an OAuth login. Use kind = \"apikey\" or drop base-urls.";
        offending = lib.filter (entry: unmatchable entry != []) entries;
      in
        lib.optionals instance.enable ([
            {
              assertion = lib.all validAliases aliasMaps;
              message = "ai.cliproxyapi.instances.${name}.settings.api-keys.claude[].tool-aliases requires 1-64 letters, digits, underscores or hyphens per name, unique upstream names, and no upstream name that is another alias source. Collisions with caller-declared tools are refused at request time.";
            }
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
          ++ lib.mapAttrsToList sharedBaseUrls config.ai.cliproxyapi.instances));
  };
}
