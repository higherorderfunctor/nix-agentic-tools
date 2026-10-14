# `ai.proxy`: point AI harnesses at a locally hosted CLIProxyAPI, so a harness
# holds only the proxy's client key and never an upstream credential.
#
# One library for every place that touches the surface:
#   * option declarations: root `ai.proxy` (sharedOptions.nix), per-runtime
#     `ai.<runtime>.proxy` (mkBackendTransform.nix), and the Home Manager
#     service records under `ai.proxy.instances` (./module.nix);
#   * selection validation, shared by both assertion sites;
#   * `resolve`, the root-to-runtime fold behind `ai.<runtime>.normalized.proxy`;
#   * the registry contract and the run-time lookup (`renderProgram`) that
#     every integration calls for the `instance` form.
#
# ── The two forms, and why one renderer serves both ──────────────────
# The `url` form is known at evaluation; the `instance` form is looked up in
# the registry only at run time (shell entry or launch), because the registry
# may be hand-written and a devenv evaluation cannot see Home Manager's. An
# integration therefore writes ONE function, `endpoint -> native config`, and
# uses it twice: on the resolved endpoint at evaluation, and on placeholder
# endpoints (`templates`) whose output `renderProgram` fills in at run time.
#
# ── The value contract ────────────────────────────────────────────────
# Placeholders are replaced by plain substring substitution, with no escaping,
# inside whatever the integration rendered: a JSON string, a TOML string, a
# shell word. That is safe only because every url and key value is held to
# `patterns`, which admit no quote, space, `$`, backslash, newline or other
# character any of those contexts treats specially. Both forms are validated
# against the same table: here at evaluation, and by render.jq at run time.
{lib}: let
  inherit (lib) mkOption types;
  credentials = import ../../credentials.nix {inherit lib;};

  keyForms = ["file" "helper" "plain"];

  # Unanchored POSIX ERE, matched whole by `builtins.match` and anchored with
  # `\A…\z` by render.jq; the syntax is the subset both engines read alike.
  patterns = {
    file = "/[A-Za-z0-9._+/=:@-]*";
    helper = "/[A-Za-z0-9._+/=:@-]*";
    plain = "[A-Za-z0-9._+/=:@-]+";
    # The origin only: each runtime appends its own protocol path (Claude
    # none, Codex `/v1`), so a path here would be doubled for one of them.
    # `[]]`, not an escaped bracket: libstdc++'s ERE rejects that escape.
    url = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  };
  patternDescriptions = {
    file = "an absolute path made of letters, digits and `._+/=:@-`";
    helper = "an absolute path made of letters, digits and `._+/=:@-`";
    plain = "letters, digits and `._+/=:@-`";
    url = "the proxy origin only, `http://<host>:<port>`, with no path";
  };

  placeholders = {
    key = "@AI_PROXY_KEY@";
    url = "@AI_PROXY_URL@";
  };

  # Relative to the XDG config home. The file format is the contract: an
  # object mapping instance name → `{url; key}`, where `key` is exactly one of
  # `{plain}`, `{file}` or `{helper}`. Home Manager writes it from
  # `ai.proxy.instances`; a proxy run by hand may have its entry written by
  # hand.
  registryPath = "ai-proxy/instances.json";

  keyType = credentials.mkSecretType {};

  # The shape of one registry entry and of a resolved `url` selection.
  endpointType = types.submodule {
    options = {
      key = mkOption {
        type = keyType;
        description = "The proxy client key the harness presents.";
      };
      url = mkOption {
        type = types.str;
        description = "The proxy origin, `http://<host>:<port>`, with no path.";
      };
    };
  };

  # `ai.<runtime>.normalized.proxy`: null when nothing is selected.
  resolvedType = types.nullOr (types.attrTag {
    endpoint = mkOption {
      type = endpointType;
      description = "An endpoint known at evaluation: the `url` form.";
    };
    instance = mkOption {
      type = types.str;
      description = "A registry instance name, looked up at run time with `lib.ai.proxy.renderProgram`.";
    };
  });

  selectionOptions = {
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "main";
      description = ''
        Name of a proxy instance in the registry,
        `''${XDG_CONFIG_HOME:-~/.config}/${registryPath}`, looked up when
        the harness's shell starts or the harness launches, never at
        evaluation. Mutually exclusive with `url` and `key`.
      '';
    };
    key = credentials.mkSecretOption {
      description = ''
        The proxy client key, required with `url`. It is the key the proxy
        accepts from clients (its `access.api-keys`), never an upstream
        credential: it reaches only the proxy, so `plain` is acceptable.
        Values are limited to ${patternDescriptions.plain} (`plain`) or
        ${patternDescriptions.file} (`file`, `helper`).
      '';
    };
    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://127.0.0.1:8317";
      description = ''
        Origin of a proxy configured by hand, used with `key`: ${patternDescriptions.url}.
        Mutually exclusive with `instance`.
      '';
    };
  };

  isSelected = selection:
    selection
    != null
    && ((selection.instance or null) != null || (selection.url or null) != null);

  urlProblem = label: url:
    lib.optional (builtins.match patterns.url url == null)
    "${label} must be ${patternDescriptions.url}, such as `http://127.0.0.1:8317`; got `${url}`.";
  keyProblem = label: key: let
    form = lib.head (builtins.attrNames key);
  in
    lib.optional (builtins.match patterns.${form} key.${form} == null)
    "${label}.${form} must be ${patternDescriptions.${form}}, so it can be substituted unescaped into JSON, TOML and shell.";

  # Every reason a selection cannot resolve, as assertion messages.
  problems = path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
  in
    lib.optional (has "instance" && (has "url" || has "key"))
    "${name}: set either `instance` (looked up in the proxy registry at run time) or `url` with `key`, not both."
    ++ lib.optional (has "url" && !has "key")
    "${name}.url needs `key`: without one the harness sends its own login token, if it has one, to the proxy."
    ++ lib.optional (has "key" && !has "url" && !has "instance")
    "${name}.key is set without `url`, so nothing uses it."
    ++ lib.optionals (has "url" && has "key" && !has "instance") (
      urlProblem "${name}.url" selection.url
      ++ keyProblem "${name}.key" selection.key
    );

  toAssertions = map (message: {
    assertion = false;
    inherit message;
  });
  assertionsFor = path: selection: toAssertions (problems path selection);

  # A per-runtime selection replaces the root one as a whole; fields never mix
  # across the two levels, so a runtime cannot pair its key with a root url.
  resolve = {
    root,
    runtime,
  }: let
    selection =
      if isSelected runtime
      then runtime
      else root;
  in
    if !isSelected selection
    then null
    else if selection.instance != null
    then {inherit (selection) instance;}
    else {endpoint = {inherit (selection) key url;};};

  originFor = {
    host,
    port,
    ...
  }: "http://${
    if lib.hasInfix ":" host
    then "[${host}]"
    else host
  }:${toString port}";

  # The registry entry for one Home Manager service record. It is also what a
  # Home Manager integration whose native config can only be written at
  # evaluation resolves its own declared instance to (Codex's user
  # config.toml): the same value, from the same generation, as the registry.
  registryEntry = inst: {
    key = inst.clientKey;
    url = originFor inst;
  };

  # An integration's renderer applied to one placeholder endpoint per key
  # form: the input `renderProgram` fills in at run time.
  templates = render:
    lib.genAttrs keyForms (form:
      render {
        key.${form} = placeholders.key;
        inherit (placeholders) url;
      });
  templatesFile = pkgs: name: render:
    pkgs.writeText "${name}-ai-proxy-templates.json" (builtins.toJSON (templates render));

  # `ai-proxy-render [--lines] INSTANCE TEMPLATES`: look INSTANCE up in the
  # registry, validate its entry against `patterns`, pick the template for its
  # key form and substitute the placeholders. Prints compact JSON, or with
  # `--lines` one line per element of a rendered array of strings (argv for a
  # launcher). Fails loudly, naming the registry and the instance, on any
  # missing or invalid input.
  renderProgram = pkgs:
    import ../../strict-shell-application.nix pkgs {
      name = "ai-proxy-render";
      text = ''
        lines=false
        if [ "''${1:-}" = --lines ]; then
          lines=true
          shift
        fi
        if [ "$#" -ne 2 ]; then
          echo "usage: ai-proxy-render [--lines] INSTANCE TEMPLATES_JSON" >&2
          exit 2
        fi
        registry="''${XDG_CONFIG_HOME:-''${HOME:?ai-proxy-render: HOME is unset}/.config}/${registryPath}"
        if [ ! -r "$registry" ]; then
          echo "ai-proxy-render: proxy instance \"$1\" is selected, but $registry is missing or unreadable. Define ai.proxy.instances.$1 in Home Manager, or write the registry entry for a proxy you run yourself." >&2
          exit 1
        fi
        if ! ${lib.getExe pkgs.jq} empty "$registry" 2>/dev/null; then
          echo "ai-proxy-render: $registry is not valid JSON." >&2
          exit 1
        fi
        exec ${lib.getExe pkgs.jq} --null-input --raw-output \
          --arg instance "$1" \
          --arg registryPath "$registry" \
          --argjson lines "$lines" \
          --argjson patterns ${lib.escapeShellArg (builtins.toJSON patterns)} \
          --argjson placeholders ${lib.escapeShellArg (builtins.toJSON placeholders)} \
          --slurpfile registry "$registry" \
          --slurpfile templates "$2" \
          --from-file ${./render.jq}
      '';
    };
  # One Home Manager service record. `settings` is CLIProxyAPI's own v8
  # configuration, passed through; `host` and `port` are lifted out because
  # the registry and the port assertion read them at evaluation, and are
  # written back into `settings.server`, so setting them in both places is a
  # definition conflict rather than a silent override.
  instanceModule = {
    jsonType,
    package,
    packageText,
  }: {config, ...}: {
    options = {
      clientKey = credentials.mkSecretOption {
        description = ''
          The client key this proxy accepts and the registry hands to
          harnesses. Rendered into the service's private config at start
          (`access.api-keys`, after any keys in `settings`); a `file` or
          `helper` is read there, so only its path reaches the store. Never
          an upstream credential. Required. Values are limited to
          ${patternDescriptions.plain} (`plain`) or ${patternDescriptions.file}
          (`file`, `helper`), and the registry holds the reference as given.
        '';
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Address the proxy listens on (`server.host`). One address only:
          CLIProxyAPI binds every interface for a blank host, so blank and
          wildcard addresses fail evaluation. Bind the address a sandbox
          reaches the host on to serve one.
        '';
      };
      package = mkOption {
        type = types.package;
        default = package;
        defaultText = packageText;
        description = "The CLIProxyAPI package the service runs.";
      };
      port = mkOption {
        type = types.port;
        default = 8317;
        description = "Port the proxy listens on (`server.port`); unique across instances.";
      };
      settings = mkOption {
        type = jsonType;
        default = {};
        example = lib.literalExpression ''{ routing.strategy = "fill-first"; }'';
        description = ''
          CLIProxyAPI configuration in its v8 layout (`server.*`,
          `access.*`, `oauth.*`, …), passed through. Plain values only: it is
          a store file, so keep secrets out of it. Logins are stored in
          `oauth.auth-dir`, which defaults to the unit's state directory,
          `$XDG_STATE_HOME/ai-proxy/<name>/auth`.
        '';
      };
    };
    config.settings.server = {inherit (config) host port;};
  };

  rootOption = {
    package,
    packageText,
    pkgs,
  }:
    mkOption {
      type = types.submodule {
        options =
          selectionOptions
          // {
            instances = mkOption {
              type = types.attrsOf (types.submodule (instanceModule {
                inherit package packageText;
                jsonType = (pkgs.formats.json {}).type;
              }));
              default = {};
              description = ''
                CLIProxyAPI services, Home Manager only (devenv rejects
                them): one systemd user unit `ai-proxy-<name>` per instance,
                Linux only for now, with a private config rendered at each
                start under `$XDG_STATE_HOME/ai-proxy/<name>`. Home Manager
                also writes the registry,
                `$XDG_CONFIG_HOME/${registryPath}`, mapping each name to its
                origin and client key, which `instance` selections read at
                run time, a devenv shell's included. Log a proxy in with
                `cliproxyapi --config $XDG_STATE_HOME/ai-proxy/<name>/config.yaml -claude-login`
                (or `-codex-login`) once the unit has started.
              '';
            };
          };
      };
      default = {};
      description = ''
        Point AI harnesses at a locally hosted CLIProxyAPI, so a harness
        holds only the proxy's client key and never an upstream credential.
        Unrelated to `ai.mcpServers.<name>.proxy`, the credential-injecting
        MCP proxy.

        Select the endpoint with `instance`, looked up at run time in the
        registry that `instances` writes, or with `url` and `key` for a proxy
        configured by hand; setting both fails evaluation.
        `ai.<runtime>.proxy` replaces this selection as a whole for one
        runtime. Home Manager's value is user-global, so a devenv shell
        inherits it with no devenv configuration; a devenv selection,
        usually in the uncommitted `devenv.local.nix`, only overrides it,
        for example to reach a second instance.

        Codex receives the selection as a model provider: Home Manager
        writes it into user config.toml, where an `instance` must be one
        Home Manager declares, and devenv's launcher passes it as session
        flags, reading an `instance` from the registry at each launch.

        A runtime that does not consume this surface warns when a selection
        reaches it: Kimchi and Kiro are not supported yet, and Copilot is
        out of scope.
      '';
    };
in {
  inherit
    assertionsFor
    endpointType
    isSelected
    keyForms
    keyProblem
    keyType
    originFor
    patterns
    placeholders
    problems
    registryEntry
    registryPath
    renderProgram
    resolve
    resolvedType
    rootOption
    selectionOptions
    templates
    templatesFile
    toAssertions
    ;
}
