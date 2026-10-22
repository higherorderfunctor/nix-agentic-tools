# `ai.cliproxyapi.instances.<name>`: CLIProxyAPI daemons, the same on both
# backends apart from the default state root. The config is rendered at each
# start from the typed settings; CLIProxyAPI's own rewrites of it (the hashed
# management key, management API saves) reach only that copy. Its auth
# directory holds the OAuth logins it writes, so it lives in `stateDir`.
# CLIProxyAPI fetches its model catalogs and its management panel from the
# network unprompted; both default off here (see docs/cliproxyapi-settings.md).
#
# Each runtime routed through an instance (`ai.<runtime>.proxy.instance`)
# publishes its key and credential rules (lib/ai/proxy `client`); the instance
# lists the key in `access.api-keys` and gives it its `access.key-allowlist`
# entry, so the module, not the consumer, owns those runtime keys.
#
# `providers` are named upstream API-key providers (../lib/providers.nix):
# each API a provider serves becomes an `api-keys.<family>` block beside any
# written by hand, and a runtime that enables the provider gets a rule naming
# that block's base URL.
backend: {
  config,
  lib,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
  providersLib = cliproxyapi.providers;
  proxyLib = import ../../../lib/ai/proxy {inherit lib;};
  nonNull = value:
    if value == null
    then []
    else value;
  # A runtime key also written by hand: a second owner of the key, or of its
  # allowlist entry, which would widen or contradict the runtime's rules.
  handWritten = name: instance: let
    clients = proxyLib.clientsOf config name;
    access = instance.settings.access or null;
    listed = field: lib.filter (value: value != null) (nonNull (access.${field} or null));
    keys = listed "api-keys";
    entries = map (entry: entry.api-key) (listed "key-allowlist");
    extra = list: client: lib.count (key: key == client.key) list > lib.count (other: other.key == client.key) clients;
    path = "ai.cliproxyapi.instances.${name}.settings.access";
  in
    lib.concatMap (client:
      lib.optional (extra keys client)
      "${path}.api-keys lists ${client.option}.key by hand; ${client.option} adds it to this instance. Remove the hand-written entry."
      ++ lib.optional (extra entries client)
      "${path}.key-allowlist has a hand-written entry for ${client.option}.key, whose entry ${client.option}.allow and .providers set. Remove the hand-written entry.")
    clients;
  # A provider's rule reaches every block of its family at its base URL, so
  # each provider block's base URL must be the only one in that family. CPA
  # trims a block's URL with Go's strings.TrimSpace (every Unicode space:
  # no-break space, FF, VT, ...) and compares the rule's URL the same way, then
  # exactly. Nix cannot reproduce that trim, so a provider URL is limited to
  # printable ASCII (../lib/providers.nix) and a hand-written URL in a
  # provider's family must start and end with a printable ASCII character,
  # which makes the trim a no-op and the exact comparison here equal to CPA's.
  printable = text: text != "" && builtins.match "[!-~]" text != null;
  edgesPrintable = url: url == "" || (printable (builtins.substring 0 1 url) && printable (builtins.substring (builtins.stringLength url - 1) 1 url));
  baseUrlOf = block: lib.defaultTo "" (block.base-url or null);
  sharedBaseUrls = name: instance: let
    served = definition: builtins.attrNames (providersLib.served definition);
    families = lib.unique (lib.concatMap (definition: map (api: providersLib.apis.${api}.family) (served definition)) (builtins.attrValues instance.providers));
    blocksOf = family: nonNull (instance.settings.api-keys.${family} or null);
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
        "ai.cliproxyapi.instances.${name}.providers.${provider}.apis.${api}.base-url `${url}` is also the base URL of another settings.api-keys.${family} block, which the provider's allowlist rule would reach too. Give each block its own base URL.")
      (served definition))
    instance.providers)
    # The name becomes a group name and a credential provider, so it stays one
    # plain word.
    ++ map (provider: "ai.cliproxyapi.instances.${name}.providers.${provider}: a provider name must be letters, digits, `.`, `_` and `-`, starting with a letter or digit.")
    (builtins.filter (provider: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" provider == null) (builtins.attrNames instance.providers));
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
      derived = {
        config,
        instance,
        name,
      }: {
        api-keys = lib.mkIf (instance.providers != {}) (providersLib.lower instance.providers);
        access = let
          clients = proxyLib.clientsOf config name;
        in
          lib.mkIf (clients != []) {
            api-keys = map (client: client.key) clients;
            key-allowlist =
              map (client: {
                api-key = client.key;
                inherit (client) credentials;
              })
              clients;
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
      extraOptions.fetchModelCatalogs = lib.mkOption {
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
      extraOptions.providers = lib.mkOption {
        type = lib.types.attrsOf providersLib.providerType;
        default = {};
        example = lib.literalExpression ''
          {
            z-ai = {
              key = redact.file config.sops.secrets.zai-key.path;
              models = ["glm-5.3"];
              apis = {
                anthropic.base-url = "https://api.z.ai/api/anthropic";
                responses.base-url = "https://api.z.ai/api/v1";
              };
            };
          }
        '';
        description = ''
          Named upstream API-key providers. Each API a provider serves
          becomes a `settings.api-keys` block with its key and models:
          `anthropic` an `api-keys.claude` block, `responses` an
          `api-keys.codex` block (with `disable-codex-cloaking`), and `chat`
          an `api-keys.openai-compatibility` group named after the provider.
          They join any blocks written by hand. A runtime reaches a provider
          only when its `ai.<runtime>.proxy.providers.<name>.enable` is set,
          through a key allowlist rule naming that block's base URL, so each
          such base URL must be the only one in its family.
        '';
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
      clients = proxyLib.clientsOf config name;
      # A runtime's entry holds the rules of its `allow`, so a refusal names
      # that option rather than the instance setting the user never wrote.
      ownerOf = entry: lib.findFirst (client: client.key == entry.api-key) null clients;
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
            assertion = lib.filter (entry: ownerOf entry == null) offending == [];
            message = "ai.cliproxyapi.instances.${name}: ${refusal "settings.access.key-allowlist"}";
          }
        ]
        ++ map (field: {
          assertion = emptied field == [];
          message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist[].credentials[].${field} merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value.";
        }) ["base-urls" "ids"]
        ++ map (client: {
          assertion = lib.all (entry: (ownerOf entry).option or null != client.option) offending;
          message = refusal "${client.option}.allow";
        })
        clients))
    config.ai.cliproxyapi.instances)
    ++ map (message: {
      assertion = false;
      inherit message;
    }) (lib.concatLists (lib.mapAttrsToList handWritten config.ai.cliproxyapi.instances
        ++ lib.mapAttrsToList sharedBaseUrls config.ai.cliproxyapi.instances));
}
