# Service metadata schema for MCP servers.
#
# Extends commonSchema.nix with service-specific fields that describe
# how a server runs as a managed service: transport modes, network
# binding, credential requirements, and tool inventory. Each server's
# `packages/<name>/modules/mcp-server.nix` returns this shape.
#
# Fields:
#   meta.modes         — { stdio = "cmd ..."; http? = "cmd ..." | "bridge"; }
#   meta.scope         — "local" | "remote"
#   meta.defaultPort?  — default port for HTTP binding (absent for stdio-only)
#   meta.honorsServiceHost? — required bool for native HTTP modes
#   meta.credentialVars? — { optionName = { envVar; required; }; }
#   meta.tools         — list of tool names advertised by the server
#   settingsOptions    — attrset of NixOS module options for typed config
#   settingsToEnv      — cfg → mode → env attrset
#   settingsToArgs     — cfg → mode → args list
_: {
  defaultServiceHost = "127.0.0.1";

  # Predicate: server has an HTTP transport mode.
  hasHttpMode = serverDef: serverDef.meta.modes ? http;

  # Predicate: server has a locally-packaged binary (not external).
  hasLocalPackage = serverDef: !(serverDef.meta ? external && serverDef.meta.external);

  # Predicate: server can run as a systemd service (local package + HTTP mode).
  hasServiceCapability = serverDef:
    !(serverDef.meta ? external && serverDef.meta.external)
    && serverDef.meta.modes ? http;

  # Whether service.host reaches the listener. Bridge mode is covered by the
  # shared mcp-proxy invocation. Native HTTP modes must record an explicit
  # audit result so changing "bridge" to a native command cannot silently
  # inherit an unverified bind-address promise.
  honorsServiceHost = name: serverDef:
    if serverDef.meta.modes.http == "bridge"
    then true
    else if !(serverDef.meta ? honorsServiceHost)
    then throw "Native HTTP MCP server ${name} must declare meta.honorsServiceHost = true or false"
    else if !(builtins.isBool serverDef.meta.honorsServiceHost)
    then throw "Native HTTP MCP server ${name} has a non-boolean meta.honorsServiceHost"
    else serverDef.meta.honorsServiceHost;
}
