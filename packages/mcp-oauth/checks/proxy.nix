# cspell:ignore nonloopback
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  backendEval = import ./backend.nix {inherit harness lib;};
  inherit (backendEval) account;
  server = port: endpoint: {
    url = "https://mcp.example.test/mcp/${endpoint}";
    proxy = {
      enable = true;
      oauthAccount = "work";
      inherit port;
    };
  };
  evaluate = backend: extra:
    backendEval.evaluate backend (lib.recursiveUpdate {
        ai = {
          claude.enable = true;
          mcp-oauth.accounts.work = account;
          mcpServers.meeting = server 19592 "meeting";
          claude.mcpServers.messaging = server 19593 "messaging";
        };
      }
      extra);
  snapshot = backend: let
    evaluated = evaluate backend {};
    cfg = evaluated.config;
    proxyServices = lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) cfg.ai.services;
  in
    assert lib.all (entry: entry.assertion) cfg.assertions; {
      clients = harness.claudeMcpServers backend evaluated;
      commands = lib.mapAttrs (_: service: service.command) proxyServices;
      proxyEnvironments = lib.mapAttrs (_: service: service.environment) proxyServices;
      restartPaths = lib.mapAttrs (_: service: service.restartOnChange) proxyServices;
      rootOwners = builtins.attrNames cfg.ai.internal.services;
      runtimeOwners = builtins.attrNames cfg.ai.claude.services;
    };
  rows = backend: let
    cfg = extra: (evaluate backend extra).config;
    # Read the selected service's command. Forcing assertions alone can leave
    # the account lookup and the generated file-header type check lazy.
    emitted = path: extra: let
      service = lib.getAttrFromPath path (cfg extra).ai;
    in
      builtins.deepSeq service.command (builtins.length service.command);
    rejectService = name: invalid:
      rejectsChange (emitted name) {
        inherit invalid;
        valid = {};
        expected = 1;
      };
    rejectRoot = rejectService ["internal" "services" "mcp-proxy-meeting"];
    rejectRuntime = rejectService ["claude" "services" "mcp-proxy-messaging"];
    # Exercise validation through the assertion path independently of active
    # service emission: an unused root entry must still obey the schema.
    inactive = {ai.claude.enable = lib.mkForce false;};
    validateUnused = extra: lib.all (entry: entry.assertion) (cfg (lib.recursiveUpdate inactive extra)).assertions;
    rejectUnused = invalid:
      rejectsChange validateUnused {
        inherit invalid;
        valid = {};
        expected = true;
      };
    rejectProxy = read: invalid:
      rejectsChange (extra: (read (cfg extra)).proxy.oauthAccount) {
        inherit invalid;
        valid = {};
        expected = "work";
      };
    rejectRootProxy = rejectProxy (config: config.ai.mcpServers.meeting);
  in
    {
      "generated header paths validate the backend state root" = rejectRoot (
        if backend == "hm"
        then {xdg.stateHome = "/bad root";}
        else {devenv.state = "/bad root";}
      );
    }
    # Schema validation and account resolution are shared before backend lowering.
    // lib.optionalAttrs (backend == "devenv") {
      "disabled accounts are not resolved" = rejectRoot {ai.mcp-oauth.accounts.work.enable = false;};
      "root proxy cannot bind a nonloopback address" = rejectRootProxy {ai.mcpServers.meeting.proxy.host = "0.0.0.0";};
      "root proxy cannot override Authorization in mixed case" = rejectRootProxy {ai.mcpServers.meeting.proxy.headers.aUtHoRiZaTiOn = "override";};
      "runtime proxy cannot delete Authorization" = rejectProxy (config: config.ai.claude.mcpServers.messaging) {ai.claude.mcpServers.messaging.proxy.headers.authorization = null;};
      "runtime proxy must resolve its own account" = rejectRuntime {ai.claude.mcpServers.messaging.proxy.oauthAccount = lib.mkForce "missing";};
      "unused root declaration cannot delete Authorization" = rejectUnused {ai.mcpServers.meeting.proxy.headers.authorization = null;};
      "unused root declaration cannot disable its OAuth proxy" = rejectUnused {ai.mcpServers.meeting.proxy.enable = lib.mkForce false;};
    };
in {
  checks = lib.all (name: checkRows "OAuth proxy (${name})" (rows name)) ["devenv" "hm"];
  snapshots = lib.genAttrs ["devenv" "hm"] snapshot;
}
