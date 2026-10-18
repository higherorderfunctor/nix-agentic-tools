# `ai.proxy`: point AI harnesses at a locally hosted CLIProxyAPI, so a harness
# holds only the proxy's client key and never an upstream credential.
#
# One library for every place that touches the surface:
#   * option declarations: root `ai.proxy` (sharedOptions.nix) and per-runtime
#     `ai.<runtime>.proxy` (mkBackendTransform.nix);
#   * selection validation, shared by both assertion sites;
#   * `resolve`, the root-to-runtime fold behind `ai.<runtime>.normalized.proxy`.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../redact {inherit lib;};
  instancesLib = import ../../../packages/ai-module/lib/instances.nix {inherit lib;};

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
        `key`, the same reference the instance lists in
        `settings.access.api-keys`.
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

  # A per-runtime selection replaces the root one as a whole; fields never mix
  # across the two levels, so a runtime cannot pair its key with a root url.
  # An instance that cannot be selected resolves to null; its assertion says why.
  resolve = {
    instances,
    root,
    runtime,
  }: let
    selection =
      if isSelected runtime
      then runtime
      else root;
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
    };

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
      `ai.cliproxyapi.instances` entry) and `key`.
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
    assertionsFor
    resolve
    resolvedType
    rootOption
    selectionOptions
    ;
}
