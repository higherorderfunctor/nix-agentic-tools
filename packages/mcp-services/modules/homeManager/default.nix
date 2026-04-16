# services.mcp-servers home-manager module.
#
# Reconstitutes the per-server typed options (enable, settings,
# credentials, service.port/host), mcpConfig output, tools registry,
# and systemd user services that were dropped during the factory
# refactor. Each server's definition is loaded from the per-package
# `packages/<name>/modules/mcp-server.nix` via lib/mcp.nix:loadServer.
#
# Picked up by collectFacet ["modules" "homeManager"] in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatLists
    concatStringsSep
    escapeShellArg
    filterAttrs
    getExe
    map
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    optionalAttrs
    optionalString
    optionals
    types
    ;

  mcpLib = import ../../../../lib/mcp.nix {inherit lib;};
  serviceSchema = import ../../../../lib/ai/mcpServer/serviceSchema.nix {inherit lib;};
  mkServiceModule = import ../../../../lib/ai/mcpServer/mkServiceModule.nix {inherit lib;};

  cfg = config.services.mcp-servers;

  # ── Server registry ────────────────────────────────────────────────
  # Maps server names to their definitions loaded from per-package
  # modules/mcp-server.nix files. The name is the package directory
  # name under packages/.
  serverNames = [
    "context7-mcp"
    "effect-mcp"
    "fetch-mcp"
    "git-intel-mcp"
    "git-mcp"
    "github-mcp"
    "kagi-mcp"
    "nixos-mcp"
    "openmemory-mcp"
    "sequential-thinking-mcp"
    "serena-mcp"
    "sympy-mcp"
  ];

  serverFiles =
    builtins.listToAttrs
    (map (name:
      nameValuePair name (mcpLib.loadServer name))
    serverNames);

  # ── Package resolution ─────────────────────────────────────────────
  # Most servers live at pkgs.ai.mcpServers.<name>. Servers from the
  # modelcontextprotocol mono-repo live under
  # pkgs.ai.mcpServers.modelContextProtocol.<name>.
  modelContextProtocolServers = [
    "fetch-mcp"
    "git-mcp"
    "sequential-thinking-mcp"
  ];

  resolvePackage = name:
    if builtins.elem name modelContextProtocolServers
    then pkgs.ai.mcpServers.modelContextProtocol.${name}
    else pkgs.ai.mcpServers.${name};

  # ── Credentials helpers ──────────────────────────────────────────────
  credentialVarsFor = name: serverFiles.${name}.meta.credentialVars or {};

  # ── Derived sets ───────────────────────────────────────────────────
  enabledServers = filterAttrs (_: srv: srv.enable) cfg.servers;

  # Servers eligible for HTTP mcpConfig entries -- must have HTTP mode
  httpServers =
    filterAttrs
    (name: _: serviceSchema.hasHttpMode serverFiles.${name})
    enabledServers;

  # Servers eligible for systemd services -- must have local package + HTTP mode
  serviceServers =
    filterAttrs
    (name: _: serviceSchema.hasServiceCapability serverFiles.${name})
    enabledServers;

  # ── Delegate entry building to lib ─────────────────────────────────
  mkHttpEntryForServer = name: srv: let
    serverDef = serverFiles.${name};
    isBridge = (serverDef.meta.modes.http or "") == "bridge";
    baseEntry = mcpLib.mkHttpEntry ({
        inherit name;
        inherit (srv) settings;
      }
      // optionalAttrs (serviceSchema.hasServiceCapability serverDef) {
        inherit (srv.service) port host;
      });
  in
    # Bridge servers use mcp-proxy which serves on /mcp
    if isBridge && !(srv.settings ? path)
    then baseEntry // {url = baseEntry.url + "/mcp";}
    else baseEntry;

  # ── Build ExecStart for systemd services ───────────────────────────
  mkExecStart = name: srv: let
    serverDef = serverFiles.${name};
    inherit (serverDef.meta) modes;
    httpCmd = modes.http;
    stdioCmdForBridge = modes.stdio;

    effectiveMode =
      if httpCmd == "bridge"
      then "stdio"
      else "http";
    srvArgs = effectiveArgsFor name srv effectiveMode;
    argsStr = concatStringsSep " " (map escapeShellArg srvArgs);
    credVars = credentialVarsFor name;
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    hasCreds = mcpLib.hasCredentials credVars evaluatedSettings;

    credSnippet =
      if hasCreds
      then mcpLib.mkCredentialsSnippet pkgs credVars evaluatedSettings
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
        ++ optionals (httpCmd == "bridge") [pkgs.ai.mcpServers.mcp-proxy];
      text = ''
        ${credSnippet}
        exec ${rawCmd}${optionalString (argsStr != "") " ${argsStr}"}
      '';
    };
  in
    getExe wrapper;

  # ── Effective env/args for systemd services ────────────────────────
  effectiveEnvFor = name: srv: mode: let
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    cfgShim = mcpLib.mkCfgShim {
      inherit evaluatedSettings;
      inherit (srv.service) port host;
    };
  in
    mcpLib.effectiveEnv name cfgShim mode srv.env;

  effectiveArgsFor = name: srv: mode: let
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
        type = types.submodule (mkServiceModule {
          inherit name serverDef resolvePackage;
        });
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
        and formatting with standard Nix functions.
      '';
    };
  };

  # ── Implementation ─────────────────────────────────────────────────
  config = {
    services.mcp-servers = {
      mcpConfig.mcpServers = mapAttrs mkHttpEntryForServer httpServers;
      tools = mapAttrs (name: _: serverFiles.${name}.meta.tools or []) enabledServers;
    };

    assertions = let
      credAssertions = concatLists (mapAttrsToList (name: srv: let
        serverDef = serverFiles.${name};
        credVars = serverDef.meta.credentialVars or {};
        evaluatedSettings = mcpLib.evalSettings name srv.settings;
      in
        concatLists (mapAttrsToList (optName: spec:
          lib.optional spec.required {
            assertion = evaluatedSettings.${optName} != null;
            message = "services.mcp-servers.servers.${name}.settings.${optName}: credentials are required (set file or helper)";
          })
        credVars))
      enabledServers);
    in
      credAssertions;

    systemd.user.services = mkIf pkgs.stdenv.isLinux (mapAttrs' (name: srv: let
      srvEnv = effectiveEnvFor name srv "http";
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
    serviceServers);
  };
}
