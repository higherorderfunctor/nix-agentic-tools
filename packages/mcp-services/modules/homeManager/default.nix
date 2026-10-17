# services.mcp-servers home-manager module.
#
# Reconstitutes the per-server typed options (enable, settings,
# credentials, service.port/host), mcpConfig output, tools registry,
# and managed daemons that were dropped during the factory
# refactor. Each server's definition is loaded from the per-package
# `packages/<name>/modules/mcp-server.nix` via lib/mcp.nix:loadServer.
#
# Picked up by native Home Manager module discovery in flake.nix.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatLists
    filterAttrs
    map
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkOption
    nameValuePair
    optionalAttrs
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
    "git-intel-mcp"
    "github-mcp"
    "gitlab-mcp"
    "kagi-mcp"
    "nixos-mcp"
  ];

  serverFiles =
    builtins.listToAttrs
    (map (name:
      nameValuePair name (mcpLib.loadServer name))
    serverNames);

  # ── Package resolution ─────────────────────────────────────────────
  # Defaults come from this flake's package tree (ai.internal.packages),
  # where every server lives at mcpServers.<name>.
  packagePath = name: "mcpServers.${name}";
  resolvePackage = name: lib.getAttrFromPath (lib.splitString "." (packagePath name)) config.ai.internal.packages;
  packageText = name: import ../../../../lib/ai/nat-package-text.nix {inherit lib;} (packagePath name);

  # ── Credentials helpers ──────────────────────────────────────────────
  credentialVarsFor = name: serverFiles.${name}.meta.credentialVars or {};

  # ── Derived sets ───────────────────────────────────────────────────
  enabledServers = filterAttrs (_: srv: srv.enable) cfg.servers;

  # Servers eligible for HTTP mcpConfig entries -- must have HTTP mode
  httpServers =
    filterAttrs
    (name: _: serviceSchema.hasHttpMode serverFiles.${name})
    enabledServers;

  # Servers eligible for managed services -- must have local package + HTTP mode
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

  # Modes carry the upstream binary and its fixed arguments. Resolve the
  # binary from the selected package, then let ai.services launch the argv.
  serviceCommand = name: srv: let
    inherit (serverFiles.${name}.meta) modes;
    bridge = modes.http == "bridge";
    mode =
      if bridge
      then "stdio"
      else "http";
    command = mcpLib.modeArgv srv.package modes.${mode} ++ effectiveArgsFor name srv mode;
  in
    if bridge
    then
      [
        "${config.ai.internal.packages.mcpServers.mcp-proxy}/bin/mcp-proxy"
        "--pass-environment"
        "--host"
        srv.service.host
        "--port"
        (toString srv.service.port)
        "--"
      ]
      ++ command
    else command;

  # ── Effective env/args for managed services ────────────────────────
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
  imports = [
    (import ../../../ai-module/lib/runtime.nix {
      enabled = enabledServers != {};
      name = "mcp-services";
    })
  ];

  # ── Options ────────────────────────────────────────────────────────
  options.services.mcp-servers = {
    servers = mapAttrs (name: serverDef:
      mkOption {
        type = types.submodule (mkServiceModule {
          inherit name packageText serverDef resolvePackage;
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
            message = "services.mcp-servers.servers.${name}.settings.${optName}: credentials are required (use redact.file or redact.command)";
          })
        credVars))
      enabledServers);
    in
      credAssertions;

    ai.mcp-services.services = mapAttrs' (name: srv: let
      evaluatedSettings = mcpLib.evalSettings name srv.settings;
      credentials = mapAttrs' (option: spec:
        nameValuePair spec.envVar evaluatedSettings.${option})
      (filterAttrs (option: _: evaluatedSettings.${option} != null) (credentialVarsFor name));
    in
      nameValuePair ("mcp-" + name) {
        command = serviceCommand name srv;
        environment = effectiveEnvFor name srv "http" // credentials;
        ports.main = srv.service.port;
      })
    serviceServers;
  };
}
