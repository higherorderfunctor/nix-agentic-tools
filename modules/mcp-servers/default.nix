{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    escapeShellArg
    filterAttrs
    map
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkOption
    nameValuePair
    optionalAttrs
    optionalString
    types
    ;

  mcpLib = import ../../lib/mcp.nix {inherit lib;};
  inherit (mcpLib) isExternal;

  cfg = config.services.mcp-servers;

  # ── Import per-server definitions ──────────────────────────────────
  serverFiles = mapAttrs (_: path:
    import path {
      inherit lib;
      mcpLib = import ../../lib/mcp.nix {inherit lib;};
    }) {
    context7-mcp = ./servers/context7-mcp.nix;
    effect-mcp = ./servers/effect-mcp.nix;
    fetch-mcp = ./servers/fetch-mcp.nix;
    github-mcp = ./servers/github-mcp.nix;
    git-intel-mcp = ./servers/git-intel-mcp.nix;
    git-mcp = ./servers/git-mcp.nix;
    kagi-mcp = ./servers/kagi-mcp.nix;
    nixos-mcp = ./servers/nixos-mcp.nix;
    openmemory-mcp = ./servers/openmemory-mcp.nix;
    sequential-thinking-mcp = ./servers/sequential-thinking-mcp.nix;
    sympy-mcp = ./servers/sympy-mcp.nix;
  };

  # ── Per-server submodule ───────────────────────────────────────────
  mkServerModule = name: serverDef: _: {
    options =
      {
        enable = mkEnableOption "the ${name} MCP server";

        settings = mkOption {
          type = types.submodule {options = serverDef.settingsOptions;};
          default = {};
          description = "Server-specific configuration for ${name}.";
        };

        env = mkOption {
          type = types.attrsOf types.str;
          default = {};
          description = "Extra environment variables (escape hatch for options not yet in settings). Values end up in the Nix store — use credentials for secrets.";
        };

        args = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra CLI arguments (escape hatch for options not yet in settings).";
        };

        scope = mkOption {
          type = types.enum ["local" "remote"];
          default = serverDef.meta.scope;
          readOnly = true;
          internal = true;
          description = "Whether the server is local (filesystem-bound) or remote.";
        };
      }
      // optionalAttrs (!(isExternal serverDef)) {
        package = mkOption {
          type = types.package;
          default = pkgs.nix-mcp-servers.${name};
          defaultText = lib.literalExpression "pkgs.nix-mcp-servers.${name}";
          description = "The ${name} package to use.";
        };

        service = {
          port = mkOption {
            type = types.port;
            default = serverDef.meta.defaultPort;
            description = "Port to bind for the HTTP service.";
          };

          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = "Host/address to bind for the HTTP service.";
          };
        };
      };
  };

  # ── Credentials helpers ──────────────────────────────────────────────
  credentialVarsFor = name: serverFiles.${name}.meta.credentialVars or {};

  # ── Derived sets ───────────────────────────────────────────────────
  enabledServers = filterAttrs (_: srv: srv.enable) cfg.servers;

  serviceServers =
    filterAttrs
    (name: _: !(isExternal serverFiles.${name}))
    enabledServers;

  # ── Delegate entry building to lib ─────────────────────────────────
  mkHttpEntry = name: srv: let
    serverDef = serverFiles.${name};
    isBridge = (serverDef.meta.modes.http or "") == "bridge";
    baseEntry = mcpLib.mkHttpEntry ({
        inherit name;
        settings = srv.settings;
      }
      // optionalAttrs (!(isExternal serverDef)) {
        inherit (srv.service) port host;
      });
  in
    # Bridge servers use mcp-proxy which serves on /mcp
    if isBridge && !(srv.settings ? path)
    then baseEntry // {url = baseEntry.url + "/mcp";}
    else baseEntry;

  # ── Build ExecStart for systemd services ───────────────────────────
  # Uses meta.modes to determine how to invoke the server.
  # "bridge" means use mcp-proxy to bridge stdio → HTTP.
  # Uses writeShellApplication with runtimeInputs for isolated PATH.
  mkExecStart = name: srv: let
    serverDef = serverFiles.${name};
    modes = serverDef.meta.modes;
    httpCmd = modes.http;
    stdioCmdForBridge = modes.stdio;

    # For bridge servers, the actual server runs in stdio mode —
    # use "stdio" to avoid http-only args like --port
    effectiveMode =
      if httpCmd == "bridge"
      then "stdio"
      else "http";
    srvArgs = effectiveArgs name srv effectiveMode;
    argsStr = concatStringsSep " " (map escapeShellArg srvArgs);
    credVars = credentialVarsFor name;
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    hasCreds = mcpLib.hasCredentials credVars evaluatedSettings;

    credSnippet =
      if hasCreds
      then mcpLib.mkCredentialsSnippet credVars evaluatedSettings
      else "";

    rawCmd =
      if httpCmd == "bridge"
      then "mcp-proxy --pass-environment --port \"$MCP_PORT\" -- ${stdioCmdForBridge}"
      else httpCmd;

    wrapper = pkgs.writeShellApplication {
      name = "mcp-" + name + "-start";
      bashOptions = ["errexit" "nounset" "pipefail" "errtrace" "functrace"];
      runtimeInputs =
        [srv.package]
        ++ lib.optionals (httpCmd == "bridge") [pkgs.nix-mcp-servers.mcp-proxy];
      text = ''
        ${credSnippet}
        exec ${rawCmd}${optionalString (argsStr != "") " ${argsStr}"}
      '';
    };
  in
    lib.getExe wrapper;

  # ── Effective env/args for systemd services ────────────────────────
  effectiveEnv = name: srv: mode: let
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    cfgShim = mcpLib.mkCfgShim {
      inherit evaluatedSettings;
      inherit (srv.service) port host;
    };
  in
    mcpLib.effectiveEnv name cfgShim mode srv.env;

  effectiveArgs = name: srv: mode: let
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    cfgShim = mcpLib.mkCfgShim {
      inherit evaluatedSettings;
      inherit (srv.service) port host;
    };
  in
    mcpLib.effectiveArgs name cfgShim mode srv.args;
in {
  # ── Options ────────────────────────────────────────────────────────
  options.services.mcp-servers = {
    servers = mapAttrs (name: serverDef:
      mkOption {
        type = types.submodule (mkServerModule name serverDef);
        default = {};
        description = "Configuration for the ${name} MCP server.";
      })
    serverFiles;

    mcpConfig = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      description = ''
        Generated mcp.json-compatible configuration from enabled servers.
        All HTTP servers produce plain { type = "http"; url = "..."; } entries.
        Reference as `config.services.mcp-servers.mcpConfig` from other modules.
      '';
    };

    tools = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      description = ''
        Tool names exposed by each enabled server (from upstream metadata).
        Use this to build client-specific auto-approval configs by filtering
        and formatting with standard Nix functions or `lib.mapTools`.
      '';
    };
  };

  # ── Implementation ─────────────────────────────────────────────────
  config = {
    services.mcp-servers = {
      mcpConfig.mcpServers = mapAttrs mkHttpEntry enabledServers;
      tools = mapAttrs (name: _: serverFiles.${name}.meta.tools or []) enabledServers;
    };

    assertions = let
      # Credential assertions: mutual exclusion is enforced by types.attrTag,
      # only required-credential checks remain.
      credAssertions = lib.concatLists (mapAttrsToList (name: srv: let
        serverDef = serverFiles.${name};
        credVars = serverDef.meta.credentialVars or {};
        evaluatedSettings = mcpLib.evalSettings name srv.settings;
      in
        lib.concatLists (mapAttrsToList (optName: spec:
          lib.optional spec.required {
            assertion = evaluatedSettings.${optName} != null;
            message = "services.mcp-servers.servers.${name}.settings.${optName}: credentials are required (set file or helper)";
          })
        credVars))
      enabledServers);
    in
      credAssertions;

    systemd.user.services = mapAttrs' (name: srv: let
      srvEnv = effectiveEnv name srv "http";
    in
      nameValuePair ("mcp-" + name) {
        Unit = {
          Description = name + " MCP server";
          After = ["network.target"];
        };
        Service = {
          Type = "simple";
          ExecStart = mkExecStart name srv;
          Restart = "on-failure";
          RestartSec = 5;
          Environment =
            [("MCP_PORT=" + toString srv.service.port)]
            ++ mapAttrsToList (k: v: k + "=" + escapeShellArg v) srvEnv;
        };
        Install = {
          WantedBy = ["default.target"];
        };
      })
    serviceServers;
  };
}
