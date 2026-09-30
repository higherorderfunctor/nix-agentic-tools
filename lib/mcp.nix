{lib}: let
  inherit
    (lib)
    any
    evalModules
    getExe
    mapAttrs
    mapAttrsToList
    ;

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
  loadServer = name: import ../packages/${name}/modules/mcp-server.nix {inherit lib mcpLib;};
  mcpLib = {inherit runtimeValues;};

  isExternal = serverDef: serverDef.meta ? external && serverDef.meta.external;

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

  runtimeValues = import ./runtime-values {inherit lib;};
  credentialsEnvironment = pkgs: credentialVars: settings:
    runtimeValues.environment {
      inherit pkgs;
      values = lib.mapAttrs' (name: spec: lib.nameValuePair spec.envVar settings.${name}) credentialVars;
    };

  # ── Credentials helpers ──────────────────────────────────────────
  # credentialVars: { settingsOptionName = { envVar = "ENV_VAR"; required = bool; }; }
  # settings: evaluated settings attrset — credentialVars keys are looked up here

  hasCredentials = credentialVars: settings:
    any (optName: let
      cred = settings.${optName};
    in
      cred != null)
    (builtins.attrNames credentialVars);

  # File paths backing file-based credentials, in declaration order.
  # Helper-based creds have no stable file to fingerprint, so they are
  # excluded. The path is stable across a rotation (only the content
  # changes), so callers hash these files to decide whether a dependent
  # long-lived service must restart. Agnostic to the secret manager
  # (sops-nix, agenix, ln, ...): it only needs the decrypted file path.
  credentialFilePaths = credentialVars: settings: env:
    lib.unique (builtins.filter (p: p != null) (
      map (value:
        if runtimeValues.isReference value && value._runtime.source ? file
        then value._runtime.source.file
        else null)
      ((mapAttrsToList (optName: _spec: settings.${optName} or null) credentialVars)
        ++ builtins.attrValues env)
    ));

  # ── Secrets wrapper for stdio servers with credentials ─────────────
  # Returns a string (store path) for use directly as a command.
  mkSecretsWrapper = {
    command,
    env,
    pkgs,
    name,
    credentialVars ? {},
    settings ? {},
  }: let
    drv = pkgs.writeShellScript (name + "-env") ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${runtimeValues.environment {
        inherit pkgs;
        values = env;
        path = ["mcpServers" name "env"];
      }}
      ${credentialsEnvironment pkgs credentialVars settings}
      exec ${lib.escapeShellArg command} "$@"
    '';
  in "${drv}";

  pythonGuard = {
    PYTHONNOUSERSITE = "true";
    PYTHONPATH = "";
  };

  normalizeStdio = pkgs: name: {
    args ? [],
    command ? null,
    credentialVars ? {},
    env,
    package ? null,
    settings ? {},
  }: let
    checkedEnv =
      (runtimeValues.keyAwareMap {
        type = lib.types.str;
        path = ["env"];
      }).merge ["mcpServers" name "env"] [
        {
          file = "renderServer";
          value = env;
        }
      ];
    executable =
      if command != null
      then command
      else getExe package;
    guarded = package != null;
    wrapped = hasCredentials credentialVars settings || any runtimeValues.isReference (builtins.attrValues checkedEnv);
  in {
    command =
      if wrapped
      then
        mkSecretsWrapper {
          inherit pkgs settings credentialVars;
          command = executable;
          env = builtins.removeAttrs checkedEnv (builtins.attrNames (
            if guarded
            then pythonGuard
            else {}
          ));
          name = name + lib.optionalString (command != null) "-raw";
        }
      else executable;
    inherit args wrapped;
    env =
      (
        if wrapped
        then {}
        else checkedEnv
      )
      // lib.optionalAttrs guarded pythonGuard;
  };

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
  #   command != null    → raw command, wrapped when env has references
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
        # A plain-string url passes through. A credential-valued url (an
        # attrset { file|helper; ... }) must have been resolved to a
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
      # (an attrset { file|helper; ... }) must have been resolved to a
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
    then let
      rendered = normalizeStdio pkgs name {inherit args command env;};
    in {
      type =
        if type != null
        then type
        else "stdio";
      inherit (rendered) args command env;
    }
    else if package != null
    then let
      serverDef = loadServer name;
      # Mode string is e.g. "github-mcp-server stdio" — split into
      # parts, drop the binary name (first element), keep only
      # subcommand/flags.
      stdioParts = lib.splitString " " serverDef.meta.modes.stdio;
      stdioArgs = builtins.tail stdioParts;
      evaluatedSettings = evalSettings name settings;
      cfgShim = mkCfgShim {inherit evaluatedSettings;};
      srvEnv = effectiveEnv name cfgShim "stdio" env;
      srvArgs = effectiveArgs name cfgShim "stdio" args;
      credentialVars = serverDef.meta.credentialVars or {};
      rendered = normalizeStdio pkgs name {
        args = stdioArgs ++ srvArgs;
        inherit credentialVars package;
        env = srvEnv;
        settings = evaluatedSettings;
      };
    in {
      type = "stdio";
      inherit (rendered) args command env;
    }
    else throw "renderServer: server '${name}' must specify one of: package, command, or url";

  mkHttpEntry = {
    name,
    host ? "127.0.0.1",
    port ? null,
    settings ? {},
  }: let
    serverDef = loadServer name;
    evaluatedSettings = evalSettings name settings;
  in
    if isExternal serverDef
    then {
      type = "http";
      inherit (evaluatedSettings) url;
    }
    else {
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
    credentialFilePaths
    effectiveArgs
    effectiveEnv
    evalSettings
    hasCredentials
    isExternal
    loadServer
    mkCfgShim
    runtimeValues
    credentialsEnvironment
    mkHttpEntry
    mkPackageEntry
    mkSecretsWrapper
    mkStdioConfig
    mkStdioEntry
    renderServer
    ;
}
