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
#   meta.credentialVars? — { optionName = { envVar; required; }; }
#   meta.tools         — list of tool names advertised by the server
#   settingsOptions    — attrset of NixOS module options for typed config
#   settingsToEnv      — cfg → mode → env attrset
#   settingsToArgs     — cfg → mode → args list
_: {
  # Predicate: server has an HTTP transport mode.
  hasHttpMode = serverDef: serverDef.meta.modes ? http;

  # Predicate: server has a locally-packaged binary (not external).
  hasLocalPackage = serverDef: !(serverDef.meta ? external && serverDef.meta.external);

  # Predicate: server can run as a systemd service (local package + HTTP mode).
  hasServiceCapability = serverDef:
    !(serverDef.meta ? external && serverDef.meta.external)
    && serverDef.meta.modes ? http;
}
