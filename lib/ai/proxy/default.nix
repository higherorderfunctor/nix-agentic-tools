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

  # The origin only: each runtime appends its own protocol path, so a path
  # here would be doubled. `[]]` avoids an escape libstdc++'s ERE rejects.
  urlPattern = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  urlDescription = "the proxy origin only, `http://<host>:<port>`, with no path";

  # The shape of a resolved `url` selection.
  endpointType = types.submodule {
    options = {
      key = mkOption {
        type = redact.types.redacted;
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
  });

  selectionOptions = {
    key = mkOption {
      type = types.nullOr redact.types.redacted;
      default = null;
      description = ''
        The proxy client key, required with `url`. It authenticates clients
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

  isSelected = selection: selection.url != null;

  urlProblem = label: url:
    lib.optional (builtins.match urlPattern url == null)
    "${label} must be ${urlDescription}, such as `http://127.0.0.1:8317`; got `${url}`.";

  # Every reason a selection cannot resolve, as assertion messages.
  problems = path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
  in
    lib.optional (has "url" && !has "key")
    "${name}.url needs `key`: without one the harness sends its own login token, if it has one, to the proxy."
    ++ lib.optional (has "key" && !has "url")
    "${name}.key is set without `url`, so nothing uses it."
    ++ lib.optionals (has "url") (urlProblem "${name}.url" selection.url);

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
    else {endpoint = {inherit (selection) key url;};};

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

      Select the endpoint with `url` and `key`.
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
