{lib}: let
  inherit
    (lib)
    any
    evalModules
    getExe
    mapAttrs
    mapAttrsToList
    ;

  redact = import ./redact {inherit lib;};

  # ── Load a server definition by name ───────────────────────────────
  # Loads on demand — no centralized server list needed in lib.
  # The server list is implicit from the caller's attrset keys (for
  # standalone mkStdioConfig) or from the factory-built HM module.
  #
  # Resolve the per-package typed MCP server module. Each MCP package
  # under packages/<name>/ owns its typed settings schema at
  # packages/<name>/modules/mcp-server.nix.
  # settingsOptions declares the public options; optional settingsModule is an
  # ordinary Nix module for config defaults and config.assertions over settings.
  # Assertion values merge with caller values; the internal option is reserved.
  loadServer = name: import ../packages/${name}/modules/mcp-server.nix {inherit lib;};

  isExternal = serverDef: serverDef.meta ? external && serverDef.meta.external;

  # The typed module of a REMOTE server keyed `name` (`meta.external`), or
  # null when `name` is not one.
  externalServer = name:
    if builtins.pathExists ../packages/${name}/modules/mcp-server.nix
    then let
      serverDef = loadServer name;
    in
      if isExternal serverDef
      then serverDef
      else null
    else null;

  # ── Evaluate settings through the module system ──────────────────
  evalSettings = name: settings: let
    serverDef = loadServer name;
    eval = evalModules {
      modules = [
        {
          # Keep the internal assertion contract even if a server declares the same key.
          options =
            serverDef.settingsOptions
            // {
              assertions = lib.mkOption {
                type = lib.types.listOf (lib.types.submodule {
                  options = {
                    assertion = lib.mkOption {type = lib.types.bool;};
                    message = lib.mkOption {type = lib.types.str;};
                  };
                });
                default = [];
                internal = true;
                description = "Settings validation, forced before any MCP renderer consumes settings.";
              };
            };
        }
        (serverDef.settingsModule or {})
        {config = settings;}
      ];
    };
    failed = builtins.filter (entry: !entry.assertion) eval.config.assertions;
  in
    if failed == []
    then builtins.removeAttrs eval.config ["assertions"]
    else throw "MCP server ${name} settings assertions failed:\n${lib.concatMapStringsSep "\n" (entry: "- ${entry.message}") failed}";

  # ── Build a cfg-compatible attrset for server definitions ────────
  # Server settingsToEnv/settingsToArgs expect { settings; service; }
  # For stdio mode, service.* is never accessed (guarded by mode == "http")
  mkCfgShim = {
    evaluatedSettings,
    port ? null,
    host ? "127.0.0.1",
  }: {
    settings = evaluatedSettings;
    service = {inherit port host;};
  };

  # ── Effective env/args (settings + escape hatches) ─────────────────
  effectiveEnv = name: cfgShim: mode: extraEnv: let
    serverDef = loadServer name;
  in
    (serverDef.settingsToEnv cfgShim mode) // extraEnv;

  effectiveArgs = name: cfgShim: mode: extraArgs: let
    serverDef = loadServer name;
  in
    (serverDef.settingsToArgs cfgShim mode) ++ extraArgs;

  # A mode string is the upstream binary and its fixed arguments, space
  # separated; the binary resolves from the selected package.
  modeArgv = package: mode: let
    parts = lib.splitString " " mode;
  in
    ["${package}/bin/${builtins.head parts}"] ++ builtins.tail parts;

  hasCredentials = credentialVars: settings:
    any (optName: settings.${optName} != null) (builtins.attrNames credentialVars);

  mkCredentialAssignments = pkgs: credentialVars: settings:
    lib.concatStringsSep "\n" (mapAttrsToList (optName: spec:
      redact.assign {
        inherit pkgs;
        option = "settings.${optName}";
        variable = spec.envVar;
        value = settings.${optName};
        export = true;
      })
    credentialVars);

  # ── Secrets wrapper for stdio servers with credentials ─────────────
  # Returns a string (store path) for use directly as a command.
  mkSecretsWrapper = {
    pkgs,
    name,
    package,
    credentialVars,
    settings,
  }: let
    drv = pkgs.writeShellScript (name + "-env") ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export PATH="${lib.makeBinPath [pkgs.coreutils]}''${PATH:+:$PATH}"
      ${mkCredentialAssignments pkgs credentialVars settings}
      exec "${getExe package}" "$@"
    '';
  in "${drv}";

  # ── Typed-shape constructor (ai.mcpServers.<name> values) ────────
  # Returns the typed shape declared in
  # `lib/ai/mcpServer/commonSchema.nix`. The per-ecosystem
  # `renderServer` is what turns this into the freeform JSON each CLI
  # consumes. Users may write the typed attrset directly in
  # `ai.mcpServers.<name>` or use this helper for symmetry with
  # `mkHttpEntry` / `mkPackageEntry`.
  mkStdioEntry = {
    package,
    settings ? {},
    env ? {},
    args ? [],
  }: {
    type = "stdio";
    inherit package settings env args;
  };

  # ── Render typed entry → freeform JSON shape ────────────────────
  # Translates a typed `commonSchema` entry into the freeform shape
  # consumed by Claude's `.mcp.json`, `.kiro/settings/mcp.json`, etc.
  # Discriminates on which fields are set, in order:
  #
  #   url != null        → HTTP pass-through
  #   command != null    → raw pass-through (no wrapping)
  #                        Explicit command always wins so users can
  #                        override or skip the server-module pipeline.
  #   package != null    → typed-via-package — runs the
  #                        server-module machinery (credentials
  #                        wrapper, mode args, settings → env)
  #
  # Called by per-ecosystem factories to produce the on-disk JSON.
  # Defensive against entries that haven't been through commonSchema
  # (use `or` defaults) so consumers can call this on a hand-built
  # typed attrset directly, not just on `config.ai.*.mcpServers`.
  renderServer = pkgs: name: srv: let
    url = srv.url or null;
    command = srv.command or null;
    package = srv.package or null;
    args = srv.args or [];
    env = srv.env or {};
    settings = srv.settings or {};
    type = srv.type or null;
    headers = srv.headers or {};
    timeout = srv.timeout or null;
  in
    if url != null
    then
      {
        type = "http";
        # A plain-string url passes through. A credential-valued url (a redact reference) must have been resolved to a
        # sentinel placeholder string by the Kiro preprocessor BEFORE
        # reaching here; if one arrives raw, a non-Kiro ecosystem is
        # rendering it (Kiro never hits this — it preprocesses first), so
        # fail loud rather than serialize the secret's file path into
        # JSON. Mirrors the credential-header guard below.
        url =
          if builtins.isAttrs url
          then throw "renderServer: credential-valued url on http server '${name}' is only supported for Kiro (ai.kiro.mcpServers); it reached the shared renderer unresolved. Non-Kiro ecosystems do not inject secret urls — use a plain-string url, or move the server to ai.kiro.mcpServers."
          else url;
      }
      # Plain-string headers pass through. A credential-valued header
      # (a redact reference) must have been resolved to a
      # `${env:VAR}` placeholder string by the Kiro preprocessor BEFORE
      # reaching here; if one arrives raw, a non-Kiro ecosystem is
      # rendering it (Kiro never hits this — it preprocesses first), so
      # fail loud rather than serialize the secret's file path into JSON.
      // lib.optionalAttrs (headers != {}) {
        headers =
          mapAttrs (
            hn: hv:
              if builtins.isAttrs hv
              then throw "renderServer: credential-valued header '${hn}' on http server '${name}' is only supported for Kiro (ai.kiro.mcpServers); it reached the shared renderer unresolved. Non-Kiro ecosystems do not inject secret headers — use a plain-string header, or move the server to ai.kiro.mcpServers."
              else hv
          )
          headers;
      }
      // lib.optionalAttrs (timeout != null) {inherit timeout;}
    else if command != null
    then {
      type =
        if type != null
        then type
        else "stdio";
      inherit command args env;
    }
    else if package != null
    then let
      serverDef = loadServer name;
      stdioArgv = modeArgv package serverDef.meta.modes.stdio;
      evaluatedSettings = evalSettings name settings;
      cfgShim = mkCfgShim {inherit evaluatedSettings;};
      srvEnv = effectiveEnv name cfgShim "stdio" env;
      srvArgs = effectiveArgs name cfgShim "stdio" args;
      credentialVars = serverDef.meta.credentialVars or {};
      needsWrapper = hasCredentials credentialVars evaluatedSettings;
      wrappedCommand = mkSecretsWrapper {
        inherit pkgs name credentialVars package;
        settings = evaluatedSettings;
      };
    in {
      type = "stdio";
      command =
        if needsWrapper
        then wrappedCommand
        else builtins.head stdioArgv;
      args = builtins.tail stdioArgv ++ srvArgs;
      # Prevent Python path pollution from parent process (e.g.,
      # nixos-mcp sets PYTHONPATH for Python 3.13 which breaks
      # Python 3.14 servers).
      env =
        srvEnv
        // {
          PYTHONPATH = "";
          PYTHONNOUSERSITE = "true";
        };
    }
    else throw "renderServer: server '${name}' must specify one of: package, command, or url";

  # ── Resolve a typed remote entry ───────────────────────────────────
  # An entry keyed by a `meta.external` server (no package, no command) carries
  # its typed values under the reserved `settings` key. This is the ONE place
  # they become the generic http fields: `url` (an explicit entry `url` wins
  # over the module default) and the module's credential headers. The headers
  # go to `proxy.headers` when the entry is proxied and to the client's
  # `headers` otherwise, where the existing Kiro-native and non-Kiro-throw
  # rules apply unchanged. Every pool reader (proxy lowering, services, client
  # fanout) calls this before looking at the entry. Anything else, including a
  # null tombstone, passes through.
  resolveRemote = name: srv: let
    serverDef = externalServer name;
    evaluatedSettings = evalSettings name (srv.settings or {});
    headers = serverDef.settingsToHeaders (mkCfgShim {inherit evaluatedSettings;});
  in
    if !(builtins.isAttrs srv) || (srv.package or null) != null || (srv.command or null) != null || serverDef == null
    then srv
    else
      removeAttrs srv ["settings"]
      // {
        type = "http";
        url =
          if (srv.url or null) != null
          then srv.url
          else evaluatedSettings.url;
      }
      // (
        if (srv.proxy or null) != null && srv.proxy.enable
        then {proxy = srv.proxy // {headers = srv.proxy.headers // headers;};}
        else {headers = (srv.headers or {}) // headers;}
      );

  mkHttpEntry = {
    name,
    host ? "127.0.0.1",
    port ? null,
    settings ? {},
  }: let
    evaluatedSettings = evalSettings name settings;
  in {
    type = "http";
    url =
      "http://"
      + host
      + ":"
      + toString port
      + (evaluatedSettings.path or "");
  };

  # ── Derive MCP entry from package passthru ─────────────────────────
  # Packages carry mcpBinary/mcpArgs in passthru; this function derives
  # a raw-command stdio entry (commonSchema shape B) without requiring a
  # server module, for consumers wiring `ai.mcpServers` directly from
  # overlay packages.
  #
  # passthru.mcpBinary — binary name when it differs from mainProgram
  # passthru.mcpArgs   — subcommand/flags (e.g. ["start-mcp-server"])
  mkPackageEntry = package: {
    type = "stdio";
    command =
      if package ? mcpBinary
      then "${package}/bin/${package.mcpBinary}"
      else getExe package;
    args = package.mcpArgs or [];
  };

  # ── Convenience: multiple servers at once ──────────────────────────
  # Takes a pkgs with the nix-agentic-tools overlay applied (exposes
  # `pkgs.ai.mcpServers.<name>`) and an attrset of per-server config
  # overrides. Each config may override the package or add
  # args/env/settings. Produces the freeform mcp.json shape directly —
  # use this for ad-hoc consumers that write mcp.json themselves.
  # For the ai.* module path, write typed entries to ai.mcpServers and
  # let the per-ecosystem factory translate.
  mkStdioConfig = pkgs: serverConfigs: {
    mcpServers = mapAttrs (name: cfg: let
      typed = mkStdioEntry ({package = pkgs.ai.mcpServers.${name};} // cfg);
    in
      renderServer pkgs name typed)
    serverConfigs;
  };
in {
  inherit
    effectiveArgs
    effectiveEnv
    evalSettings
    hasCredentials
    isExternal
    loadServer
    mkCfgShim
    mkCredentialAssignments
    mkHttpEntry
    mkPackageEntry
    mkSecretsWrapper
    mkStdioConfig
    mkStdioEntry
    modeArgv
    renderServer
    resolveRemote
    ;
}
