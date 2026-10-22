# `ai.proxy`: point AI harnesses at a locally hosted CLIProxyAPI, so a harness
# holds only the proxy's client key and never an upstream credential.
#
# One library for every place that touches the surface:
#   * option declarations: root `ai.proxy` (sharedOptions.nix) and per-runtime
#     `ai.<runtime>.proxy` (mkBackendTransform.nix);
#   * selection validation, shared by both assertion sites;
#   * `resolve`, the root-to-runtime fold behind `ai.<runtime>.normalized.proxy`;
#   * `providersFor`, enabled provider rules resolved against the instance;
#   * `client` publishes routed runtime keys; `clientsOf` selects them for an
#     instance's access list and allowlist.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../redact {inherit lib;};
  instancesLib = import ../../../packages/ai-module/lib/instances.nix {inherit lib;};
  inherit (import ../../../packages/cliproxyapi/lib/default.nix {inherit lib;}) cliproxyapi;
  apiNames = builtins.attrNames cliproxyapi.providers.apis;

  # The origin only: each runtime appends its own protocol path, so a path
  # here would be doubled. `[]]` avoids an escape libstdc++'s ERE rejects.
  urlPattern = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  urlDescription = "the proxy origin only, `http://<host>:<port>`, with no path";

  # `ai.<runtime>.normalized.proxy`: null or the selected endpoint record.
  resolvedType = types.nullOr (types.submodule {
    options = {
      key = mkOption {
        type = redact.types.redacted;
        description = "The proxy client key the harness presents.";
      };
      # What a runtime offers in its model choice: each enabled provider and
      # the models its instance lists for it.
      providers = mkOption {
        type = types.listOf (types.submodule {
          options = {
            models = mkOption {
              type = types.nonEmptyListOf types.str;
              description = "The provider's models.";
            };
            name = mkOption {
              type = types.str;
              description = "The provider's `ai.cliproxyapi.instances.<n>.providers` name.";
            };
          };
        });
        default = [];
        description = "The enabled providers of an instance selection, in name order.";
      };
      # Typed, not only asserted: normalized options are a public input, and
      # a value set here directly skips the selection assertions.
      url = mkOption {
        type = types.strMatching urlPattern;
        description = "The proxy origin, `http://<host>:<port>`, with no path.";
      };
    };
  });

  selectionOptions = {
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "main";
      description = ''
        An `ai.cliproxyapi.instances` entry to use instead of `url`: the
        origin becomes that instance's `http://127.0.0.1:<port>`. Pair it with
        `key`. Each enabled runtime this selection reaches adds `key` to the
        instance's `settings.access.api-keys`, with an
        `access.key-allowlist` entry from its `ai.<runtime>.proxy.allow` and
        enabled providers, so do not list the key there by hand. Evaluation
        claims the key's reference; CLIProxyAPI refuses distinct references
        that resolve to the same value at start or on reload.
      '';
    };
    key = mkOption {
      type = types.nullOr redact.types.redacted;
      default = null;
      description = ''
        The proxy client key, required with `url` or `instance`. It authenticates clients
        against the proxy's `access.api-keys`, never an upstream credential.
        Use `redact.file`, `redact.command` or `redact.concat` to keep the key
        out of the Nix store; its value is read when a consuming harness starts.
        Give each runtime a key with a distinct value.
      '';
    };
    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://127.0.0.1:8317";
      description = ''
        Origin of a proxy configured by hand, used with `key`: ${urlDescription}.
      '';
    };
  };

  isSelected = selection: selection.url != null || selection.instance != null;

  # A per-runtime selection replaces the root one as a whole; fields never mix
  # across the two levels, so a runtime cannot pair its key with a root url.
  selectionFor = root: runtime:
    if isSelected runtime
    then runtime
    else root;

  # `allow` and `providers` apply to whichever selection scope wins.
  runtimeOptions = {
    api,
    default,
    name,
  }:
    selectionOptions
    // {
      allow = mkOption {
        type = cliproxyapi.keyAllowlistCredentialsType;
        inherit default;
        example = [
          {
            kind = "oauth";
            provider = "claude";
          }
        ];
        description = ''
          The credentials ${name}'s client key may select when its proxy
          selection names an `instance`: that key's
          `access.key-allowlist` entry in the instance, one rule per
          credential `provider` and `kind` (`oauth` or `apikey`), optionally
          narrowed by `ids`. The instance fails closed, so a request with
          this key reaches nothing else. ${
            if default == null
            then "${name} has no native CLIProxyAPI provider, so an instance selection needs this set."
            else "The default is ${name}'s own login."
          } Enabled providers add rules beside these; set `allow = []` to use
          only providers. Unused with `url`.
        '';
      };
      providers = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            api = mkOption {
              type = types.nullOr (types.enum apiNames);
              default = null;
              description = ''
                The provider API ${name} reaches it through${
                  if api == null
                  then "; ${name} speaks none by default, so set it"
                  else ". Null means `${api}`, the API ${name} speaks"
                }. The provider must serve it.
              '';
            };
            enable = lib.mkEnableOption "routing ${name} to this provider of the selected instance";
          };
        });
        default = {};
        example = lib.literalExpression ''{z-ai.enable = true;}'';
        description = ''
          Providers of the selected instance that ${name}'s key may reach.
          Each enabled provider adds a base-URL rule on the selected API and
          offers its models to ${name}. Requires an `instance` selection.
        '';
      };
    };

  # `ai.cliproxyapi.instances` is read where a selection is validated or
  # resolved; an evaluation without the owner module has no instances.
  instanceSelection = instances: path: selection:
    instancesLib.select {
      inherit instances;
      name = selection.instance;
      option = "${lib.showOption path}.instance";
      owner = "cliproxyapi";
    };

  urlProblem = label: url:
    lib.optional (builtins.match urlPattern url == null)
    "${label} must be ${urlDescription}, such as `http://127.0.0.1:8317`; got `${url}`.";

  # Every reason a selection cannot resolve, as assertion messages.
  problems = instances: path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
    field =
      if has "url"
      then "url"
      else "instance";
  in
    lib.optional (has "url" && has "instance")
    "${name}.url and ${name}.instance both select a proxy; set one."
    ++ lib.optional (isSelected selection && !has "key")
    "${name}.${field} needs `key`: without one the harness sends its own login token, if it has one, to the proxy."
    ++ lib.optional (has "key" && !isSelected selection)
    "${name}.key is set without `url` or `instance`, so nothing uses it."
    ++ lib.optionals (has "url") (urlProblem "${name}.url" selection.url)
    ++ lib.optionals (has "instance") (lib.toList ((instanceSelection instances path selection).problem or []));

  toAssertions = map (message: {
    assertion = false;
    inherit message;
  });
  assertionsFor = instances: path: selection: toAssertions (problems instances path selection);

  # An instance that cannot be selected resolves to null; its assertion says
  # why. `providers` is `providersFor`'s `resolved`.
  resolve = {
    instances,
    providers,
    root,
    runtime,
  }: let
    selection = selectionFor root runtime;
    url =
      if selection.instance != null
      then (instanceSelection instances [] selection).url or null
      else selection.url;
  in
    if !isSelected selection || url == null
    then null
    else {
      inherit (selection) key;
      inherit url;
      providers = map (provider: {inherit (provider) models name;}) providers;
    };

  # A missing instance resolves no provider; selection validation reports it.
  # Resolved providers carry each provider's name, models and allowlist rule.
  providersFor = {
    api,
    instances,
    option,
    providers,
    selection,
  }: let
    enabled = lib.filterAttrs (_: choice: choice.enable) providers;
    instance =
      if selection.instance == null
      then null
      else instances.${selection.instance} or null;
    declared = "ai.cliproxyapi.instances.${selection.instance}.providers";
    one = name: choice: let
      provider = instance.providers.${name} or null;
      chosen =
        if choice.api != null
        then choice.api
        else api;
      served = builtins.attrNames (cliproxyapi.providers.served provider);
      path = "${option}.providers.${name}";
    in
      if selection.instance == null
      then {problem = "${path} needs an `instance` selection: the module routes to a provider only through an instance it configures, never a `url` proxy.";}
      else if instance == null
      then {}
      else if provider == null
      then {problem = "${path} names `${name}`, which is not a `${declared}` entry.";}
      else if chosen == null
      then {problem = "${path}.api is unset, and nothing sets a default API: set it to one ${declared}.${name} serves (${lib.concatStringsSep ", " served}).";}
      else if !lib.elem chosen served
      then {problem = "${path} reaches ${declared}.${name} through the ${chosen} API, which it does not serve: give it `apis.${chosen}`, or set `${path}.api` to one it serves (${lib.concatStringsSep ", " served}).";}
      else {
        resolved = {
          inherit name;
          inherit (provider) models;
          rule = cliproxyapi.providers.rule name provider chosen;
        };
      };
    results = lib.mapAttrsToList one enabled;
  in {
    problems = lib.concatMap (result: lib.toList (result.problem or [])) results;
    resolved = lib.concatMap (result: lib.toList (result.resolved or [])) results;
  };

  # A url selection is configured by hand; an enabled instance selection
  # publishes its key, `allow` rules, and resolved provider rules.
  client = {
    option,
    providers,
    root,
    runtime,
  }: let
    selection = selectionFor root runtime;
  in
    if selection.instance == null || selection.key == null
    then null
    else {
      inherit option;
      inherit (selection) instance key;
      inherit (runtime) allow;
      inherit providers;
    };

  # The published clients of instance `name`, ordered by runtime name.
  clientsOf = config: name: builtins.filter (client: client.instance == name) (builtins.attrValues (config.ai.internal.proxyClients or {}));

  # A client key's `ai.claims.proxy-client-key` key. A reference is data, so
  # equal references are one key; the claim prints the reference, never a value.
  keyClaim = key: builtins.unsafeDiscardStringContext (builtins.toJSON key);

  # `providers` is `providersFor`'s result.
  clientAssertions = client: providers:
    toAssertions (providers.problems
      ++ lib.optional (client != null && client.allow == null && providers.resolved == [])
      "${client.option}.allow is unset and no provider is enabled, and ${client.option}.instance needs one of them: the instance's key allowlist fails closed, so name the credentials this key may select.");

  rootOption = mkOption {
    type = types.submodule {
      options = selectionOptions;
    };
    default = {};
    description = ''
      Point AI harnesses at a locally hosted CLIProxyAPI, so a harness
      holds only the proxy's client key and never an upstream credential.
      Unrelated to `ai.mcpServers.<name>.proxy`, the credential-injecting
      MCP proxy.

      Select the endpoint with `url` and `key`, or with `instance` (an
      `ai.cliproxyapi.instances` entry) and `key`. An instance gets each
      routed runtime's key and allowlist entry from the module; every
      runtime needs its own key, so a root `instance` selection serves one
      enabled runtime, and each other runtime selects with its own.
      `ai.<runtime>.proxy`, declared only for a runtime that consumes
      this surface, replaces this selection as a whole for that runtime.

      Claude Code reads the selection from its settings files: the
      settings.json each backend writes.

      Codex receives the selection as a model provider: Home Manager
      writes it into user config.toml, and devenv's launcher passes it as
      session flags.

      A runtime that does not consume this surface warns when a selection
      reaches it.
    '';
  };
in {
  inherit
    apiNames
    assertionsFor
    client
    clientAssertions
    clientsOf
    keyClaim
    providersFor
    resolve
    resolvedType
    rootOption
    runtimeOptions
    selectionFor
    ;
}
