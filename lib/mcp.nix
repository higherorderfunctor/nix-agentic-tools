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
  # The server list lives in modules/home-manager.nix (for HM) or is
  # implicit from the caller's attrset keys (for standalone mkStdioConfig).
  loadServer = name: import ../modules/servers/${name}.nix {inherit lib mcpLib;};
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

  mkCredentialsSnippet = credentialVars: settings:
    concatStringsSep "\n" (mapAttrsToList (optName: spec: let
      cred = settings.${optName};
      envVar = spec.envVar;
    in
      if cred.helper or null != null
      then ''
        ${envVar}="$("${cred.helper}")"
        export ${envVar}''
      else if cred.file or null != null
      then ''
        ${envVar}="$(cat "${cred.file}")"
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
      ${mkCredentialsSnippet credentialVars settings}
      exec "${getExe package}" "$@"
    '';
  in "${drv}";

  # ── mcp.json entry builders ─────────────────────────────────────
  mkStdioEntry = pkgs: {
    package,
    name ? package.passthru.mcpName or package.pname,
    settings ? {},
    env ? {},
    args ? [],
  }: let
    serverDef = loadServer name;
    # Mode string is e.g. "github-mcp-server stdio" — split into parts,
    # drop the binary name (first element), keep only subcommand/flags
    stdioParts = lib.splitString " " serverDef.meta.modes.stdio;
    stdioArgs = builtins.tail stdioParts;
    evaluatedSettings = evalSettings name settings;
    cfgShim = mkCfgShim {inherit evaluatedSettings;};
    srvEnv = effectiveEnv name cfgShim "stdio" env;
    srvArgs = effectiveArgs name cfgShim "stdio" args;
    credentialVars = serverDef.meta.credentialVars or {};
    needsWrapper = hasCredentials credentialVars evaluatedSettings;
    wrappedCommand = mkSecretsWrapper {
      inherit pkgs name package credentialVars;
      settings = evaluatedSettings;
    };
  in
    {
      type = "stdio";
      command =
        if needsWrapper
        then wrappedCommand
        else getExe package;
      args = stdioArgs ++ srvArgs;
    }
    # Prevent Python path pollution from parent process (e.g., nixos-mcp
    # sets PYTHONPATH for Python 3.13 which breaks Python 3.14 servers)
    // {
      env =
        srvEnv
        // {
          PYTHONPATH = "";
          PYTHONNOUSERSITE = "true";
        };
    };

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
      url = evaluatedSettings.url;
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

  # ── Convenience: multiple servers at once ──────────────────────────
  mkStdioConfig = pkgs: serverConfigs: {
    mcpServers = mapAttrs (name: cfg:
      mkStdioEntry pkgs ({package = pkgs.nix-mcp-servers.${name};} // cfg))
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
    mkSecretsWrapper
    mkStdioConfig
    mkStdioEntry
    ;
}
