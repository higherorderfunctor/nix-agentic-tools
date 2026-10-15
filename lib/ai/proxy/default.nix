# `ai.proxy`: point AI harnesses at a locally hosted CLIProxyAPI, so a harness
# holds only the proxy's client key and never an upstream credential.
#
# One library for every place that touches the surface:
#   * option declarations: root `ai.proxy` (sharedOptions.nix) and per-runtime
#     `ai.<runtime>.proxy` (mkBackendTransform.nix);
#   * selection validation, shared by both assertion sites;
#   * `resolve`, the root-to-runtime fold behind `ai.<runtime>.normalized.proxy`.
#
# ── The value contract ────────────────────────────────────────────────
# Every url and key value is held to `patterns`, which admit no quote, space,
# `$`, backslash, newline or other character that a JSON string, a TOML string
# or a double-quoted shell string treats specially, so a consumer can
# substitute one there unescaped. An unquoted shell word is not safe: the url
# pattern admits `[` and `]`, which bash glob-expands.
{lib}: let
  inherit (lib) mkOption types;
  credentials = import ../../credentials.nix {inherit lib;};

  # Unanchored POSIX ERE, matched whole by `builtins.match`.
  patterns = {
    file = "/[A-Za-z0-9._+/=:@-]*";
    helper = "/[A-Za-z0-9._+/=:@-]*";
    plain = "[A-Za-z0-9._+/=:@-]+";
    # The origin only: each runtime appends its own protocol path, so a path
    # here would be doubled.
    # `[]]`, not an escaped bracket: libstdc++'s ERE rejects that escape.
    url = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  };
  patternDescriptions = {
    file = "an absolute path made of letters, digits and `._+/=:@-`";
    helper = "an absolute path made of letters, digits and `._+/=:@-`";
    plain = "letters, digits and `._+/=:@-`";
    url = "the proxy origin only, `http://<host>:<port>`, with no path";
  };

  keyType = credentials.mkSecretType {};

  # The shape of a resolved `url` selection.
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
  });

  selectionOptions = {
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
      '';
    };
  };

  isSelected = selection: selection.url != null;

  urlProblem = label: url:
    lib.optional (builtins.match patterns.url url == null)
    "${label} must be ${patternDescriptions.url}, such as `http://127.0.0.1:8317`; got `${url}`.";
  keyProblem = label: key: let
    form = lib.head (builtins.attrNames key);
  in
    lib.optional (builtins.match patterns.${form} key.${form} == null)
    "${label}.${form} must be ${patternDescriptions.${form}}, so it can be substituted unescaped into JSON, TOML and a double-quoted shell string.";

  # Every reason a selection cannot resolve, as assertion messages.
  problems = path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
  in
    lib.optional (has "url" && !has "key")
    "${name}.url needs `key`: without one the harness sends its own login token, if it has one, to the proxy."
    ++ lib.optional (has "key" && !has "url")
    "${name}.key is set without `url`, so nothing uses it."
    ++ lib.optionals (has "url" && has "key") (
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
      this surface (none yet), replaces this selection as a whole for that
      runtime.

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
