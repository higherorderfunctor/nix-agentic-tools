{lib}: let
  inherit
    (lib)
    any
    concatStringsSep
    evalModules
    getExe
    mapAttrs
    mapAttrsToList
    mkOption
    types
    ;

  # ── Load a server definition by name ───────────────────────────────
  # Loads on demand — no centralized server list needed in lib.
  # The server list is implicit from the caller's attrset keys (for
  # standalone mkStdioConfig) or from the factory-built HM module.
  #
  # Resolve the per-package typed MCP server module. Each MCP package
  # under packages/<name>/ owns its typed settings schema at
  # packages/<name>/modules/mcp-server.nix.
  loadServer = name: import ../packages/${name}/modules/mcp-server.nix {inherit lib mcpLib;};
  mcpLib = {inherit mkCredentialsOption;};

  isExternal = serverDef: serverDef.meta ? external && serverDef.meta.external;

  # ── Evaluate settings through the module system ──────────────────
  evalSettings = name: settings: let
    serverDef = loadServer name;
    eval = evalModules {
      modules = [
        {options = serverDef.settingsOptions;}
        {config = settings;}
      ];
    };
  in
    eval.config;

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

  # ── Credentials option generator ──────────────────────────────────
  # Creates a discriminated union (attrTag) option for a single credential.
  # Exactly one of `file` or `helper` may be set; the type system enforces
  # mutual exclusion (no runtime assertion needed). Wrapped in nullOr so
  # optional credentials default to null.
  mkCredentialsOption = envVar:
    mkOption {
      type = types.nullOr (types.attrTag {
        file = mkOption {
          type = types.str;
          description = ''
            Path to a file containing the raw secret value, read at runtime.
            Not stored in the Nix store. Works with sops-nix, agenix, or any
            tool that decrypts secrets to files. Mapped to ${envVar}.
          '';
        };
        helper = mkOption {
          type = types.str;
          description = ''
            Path to an executable that outputs the raw secret value on stdout.
            Executed at service start. Mapped to ${envVar}.
          '';
        };
      });
      default = null;
      description = "Credential mapped to ${envVar}. Set exactly one of file or helper.";
    };

  # ── Credentials helpers ──────────────────────────────────────────
  # credentialVars: { settingsOptionName = { envVar = "ENV_VAR"; required = bool; }; }
  # settings: evaluated settings attrset — credentialVars keys are looked up here

  hasCredentials = credentialVars: settings:
    any (optName: let
      cred = settings.${optName};
    in
      (cred.file or null) != null || (cred.helper or null) != null)
    (builtins.attrNames credentialVars);

  # Use absolute paths for all commands — Claude Code's MCP `env` field
  # replaces the process environment (no PATH inheritance), so bare
  # command names like `cat` fail with "command not found".
  mkCredentialsSnippet = pkgs: credentialVars: settings:
    concatStringsSep "\n" (mapAttrsToList (optName: spec: let
      cred = settings.${optName};
      inherit (spec) envVar;
    in
      if cred.helper or null != null
      then ''
        ${envVar}="$("${cred.helper}")"
        export ${envVar}''
      else if cred.file or null != null
      then ''
        ${envVar}="$(${pkgs.coreutils}/bin/cat "${cred.file}")"
        export ${envVar}''
      else "")
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
      ${mkCredentialsSnippet pkgs credentialVars settings}
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
  # consumed by `programs.claude-code.mcpServers`, `.kiro/settings/
  # mcp.json`, etc. Discriminates on which fields are set, in order:
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
  renderServer = pkgs: name: srv:
    if srv.url != null
    then {
      type = "http";
      inherit (srv) url;
    }
    else if srv.command != null
    then {
      type =
        if srv.type != null
        then srv.type
        else "stdio";
      inherit (srv) command args env;
    }
    else if srv.package != null
    then let
      serverDef = loadServer name;
      # Mode string is e.g. "github-mcp-server stdio" — split into
      # parts, drop the binary name (first element), keep only
      # subcommand/flags.
      stdioParts = lib.splitString " " serverDef.meta.modes.stdio;
      stdioArgs = builtins.tail stdioParts;
      evaluatedSettings = evalSettings name srv.settings;
      cfgShim = mkCfgShim {inherit evaluatedSettings;};
      srvEnv = effectiveEnv name cfgShim "stdio" srv.env;
      srvArgs = effectiveArgs name cfgShim "stdio" srv.args;
      credentialVars = serverDef.meta.credentialVars or {};
      needsWrapper = hasCredentials credentialVars evaluatedSettings;
      wrappedCommand = mkSecretsWrapper {
        inherit pkgs name credentialVars;
        inherit (srv) package;
        settings = evaluatedSettings;
      };
    in {
      type = "stdio";
      command =
        if needsWrapper
        then wrappedCommand
        else getExe srv.package;
      args = stdioArgs ++ srvArgs;
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
  # a stdio entry without requiring a server module. Used by devenv and
  # consumers who wire MCP servers directly from overlay packages.
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
    mkCredentialsOption
    mkCredentialsSnippet
    mkHttpEntry
    mkPackageEntry
    mkSecretsWrapper
    mkStdioConfig
    mkStdioEntry
    renderServer
    ;
}
