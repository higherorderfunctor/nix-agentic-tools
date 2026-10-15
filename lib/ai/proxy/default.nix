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
#     every devenv integration calls for the `instance` form.
#
# ── The two forms, and why one renderer serves both ──────────────────
# The `url` form is known at evaluation. On Home Manager, so is an
# `instance`: it names one of Home Manager's own `instances`, and resolves to
# the entry Home Manager writes to the registry in the same generation, so
# each runtime's user files stay ordinary evaluated files. On devenv the
# `instance` form is looked up in the registry only at run time (shell entry
# or launch), because the registry may be hand-written and a devenv
# evaluation cannot see Home Manager's. An integration therefore writes ONE
# function, `endpoint -> native config`, and uses it twice: on the resolved
# endpoint at evaluation, and on placeholder endpoints (`templates`) whose
# output `renderProgram` fills in at run time.
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
  cliproxyapi = import ../../../packages/cliproxyapi/lib/extracted.nix {inherit lib;};
  credentials = import ../../credentials.nix {inherit lib;};
  openKeys = import ../../open-keys {inherit lib;};

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
      description = "An endpoint known at evaluation: the `url` form, or an `instance` Home Manager declares.";
    };
    instance = mkOption {
      type = types.str;
      description = "A registry instance name, looked up at run time with `lib.ai.proxy.renderProgram` (devenv).";
    };
  });

  selectionOptions = {
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "main";
      description = ''
        Name of a proxy instance. Home Manager resolves it at evaluation
        against its own `ai.proxy.instances`, so it must be one declared
        there. devenv looks it up in the registry,
        `''${XDG_CONFIG_HOME:-~/.config}/${registryPath}`, when the
        harness's shell starts or the harness launches, never at
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
    "${name}: set either `instance` (a named proxy instance) or `url` with `key`, not both."
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
  # `instances` are Home Manager's: an `instance` among them resolves to its
  # registry entry. A name it does not declare stays a name, for
  # `hmInstanceAssertions` to reject, as does one without a client key, which
  # the instance's own assertion rejects.
  resolve = {
    instances,
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
    else if selection.instance == null
    then {endpoint = {inherit (selection) key url;};}
    else if (instances.${selection.instance}.clientKey or null) != null
    then {endpoint = registryEntry instances.${selection.instance};}
    else {inherit (selection) instance;};

  # Home Manager writes each runtime's proxy settings at evaluation, so its
  # `instance` must be one it declares.
  hmInstanceAssertions = {
    instances,
    resolved,
    runtime,
  }:
    toAssertions (lib.optional (resolved ? instance && !(instances ? ${resolved.instance}))
      "ai.${runtime} is pointed at ai.proxy instance \"${resolved.instance}\", which Home Manager does not declare in ai.proxy.instances. Home Manager writes the harness's proxy settings at evaluation, so it can only use an instance it declares. Declare it, or select a proxy you run yourself with ai.proxy.url and ai.proxy.key (or ai.${runtime}.proxy.url and .key).");

  originFor = {
    host,
    port,
    ...
  }: "http://${
    if lib.hasInfix ":" host
    then "[${host}]"
    else host
  }:${toString port}";

  # The registry entry for one Home Manager service record, and what `resolve`
  # turns a Home Manager `instance` into: the same value, from the same
  # generation.
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
  # configuration, typed from the extraction; `host` and `port` are lifted out
  # because the registry and the port assertion read them at evaluation, and
  # are written back into `settings.server`, so setting them in both places is
  # a definition conflict rather than a silent override.
  instanceModule = {
    jsonType,
    package,
    packageText,
  }: {config, ...}: {
    options = {
      accounts = mkOption {
        type = types.attrsOf (cliproxyapi.accountType {inherit jsonType;});
        default = {};
        example = lib.literalExpression ''{ "claude-1a2b3c4d-you@example.com" = { priority = 10; }; }'';
        description = ''
          Settings for each OAuth login, keyed by its auth file's name in
          `oauth.auth-dir` without `.json`: `claude-<hash>-<email>` for a
          Claude login (`claude-<email>` when the account reports no
          organization or account id) and `codex-<hash>-<email>-<plan>` for a
          Codex login, where the hash is fixed per organization or account.
          List the auth dir after logging in to read it; a Codex plan change
          logs in under a new name. The typed options are the auth-file
          fields the extraction finds CLIProxyAPI reading, apart from the
          login's identity and tokens. Any other key is written as given,
          untyped, with an unknown-key warning: fields CLIProxyAPI's
          executors and management panel use off that path, such as
          `request_retry`, `websockets`, `disable_cooling` or the `cloak_*`
          fields. A key naming the
          login's identity or a token (`type`, `email`, `id_token`,
          `plan_type`, or a credential-shaped name such as `access_token`
          or `api_key`) fails evaluation: the login writes those, and Nix
          never writes or owns them.
          At every start the unit writes each set field into that file and
          skips a file that does not exist yet. It owns only what it wrote:
          a field or account removed here is removed from the file at the
          next start, a field set in CLIProxyAPI's management panel and
          never declared here is left alone, and a declared field edited in
          the panel is reset.
        '';
      };
      allowUnrecognizedAccountFields = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["*.request_retry"];
        description = ''
          Suppress unknown-key warnings at these paths relative to
          `accounts`, `*` standing for every account name. An entry never
          permits an identity or credential field.
          ${openKeys.allowlistSyntax}
        '';
      };
      allowUnrecognizedSettings = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["server.future-field"];
        description = ''
          Suppress unknown-key warnings at these paths relative to `settings`.
          Unknown keys remain writable without an allowlist entry.
          ${openKeys.allowlistSyntax}
        '';
      };
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
        type = cliproxyapi.settingsType {inherit jsonType;};
        default = {};
        example = lib.literalExpression ''
          {
            routing.strategy = "fill-first";
            api-keys.claude = [
              { keys = [ { api-key.file = "/run/secrets/anthropic-key"; } ]; }
            ];
          }
        '';
        description = ''
          CLIProxyAPI configuration in its v8 layout (`server.*`,
          `access.*`, `oauth.*`, …), typed from the pinned CLIProxyAPI's own
          configuration structs; a key the typing does not know passes
          through as written, with an unknown-key warning. Unset options are
          left out, so CLIProxyAPI keeps its defaults. A credential, such as
          an upstream `api-key`, and a value that can carry one (a
          `proxy-url`, an upstream `headers` value) takes `plain`, `file` or
          `helper`: the start script reads a `file` or `helper` and writes its contents in that place of the private
          config, failing the unit if the file is missing or empty or the
          helper fails, and only the path reaches the store. Logins are
          stored in `oauth.auth-dir`, which defaults to the unit's state
          directory, `$XDG_STATE_HOME/ai-proxy/<name>/auth`.
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
                origin and client key, which devenv `instance` selections
                read at run time. Log a proxy in with
                `cliproxyapi --config $XDG_STATE_HOME/ai-proxy/<name>/config.yaml -claude-login`
                (or `-codex-login`, `-codex-device-login`) once the unit has
                started; the running proxy picks the login up without a
                restart, and writes its declared `accounts` fields at the
                next start (`systemctl --user restart ai-proxy-<name>`).
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

        Select the endpoint with `instance` or, for a proxy configured by
        hand, with `url` and `key`; setting both fails evaluation. Home
        Manager resolves `instance` at evaluation against its own
        `instances`, and fails evaluation on a name it does not declare.
        devenv looks `instance` up at run time in the registry, which Home
        Manager writes from `instances` and a proxy run by hand may have
        written by hand.
        `ai.<runtime>.proxy` replaces this selection as a whole for one
        runtime. Home Manager's value is user-global, so a devenv shell
        inherits it with no devenv configuration; a devenv selection,
        usually in the uncommitted `devenv.local.nix`, only overrides it,
        for example to reach a second instance.

        Claude Code reads the selection from its settings files: the
        settings.json each backend writes, except an `instance` on devenv,
        which is rendered at shell entry into the project's
        `.claude/settings.local.json`.

        Codex receives the selection as a model provider: Home Manager
        writes it into user config.toml, and devenv's launcher passes it as
        session flags, reading an `instance` from the registry at each
        launch.

        A runtime that does not consume this surface warns when a selection
        reaches it: Kimchi and Kiro are not supported yet, and Copilot is
        out of scope.
      '';
    };
in {
  inherit
    assertionsFor
    endpointType
    hmInstanceAssertions
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
