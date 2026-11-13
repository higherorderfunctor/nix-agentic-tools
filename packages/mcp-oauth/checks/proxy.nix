{
  harness,
  lib,
  pkgs,
  ...
}: let
  backendEval = import ./backend.nix {inherit harness lib;};
  inherit (backendEval) account;
  proxy = import ../../../lib/ai/mcpProxy.nix {inherit lib pkgs;};
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
    stateRoot =
      if backend == "hm"
      then cfg.xdg.stateHome
      else cfg.devenv.state;
    resolve = import ../lib/resolve-proxy.nix {inherit lib;} {
      accounts = cfg.ai.mcp-oauth.accounts;
      inherit backend stateRoot;
    };
    spec =
      proxy.specFor "meeting"
      (resolve {
        key = "meeting";
        optionPath = "ai.mcpServers";
        server = cfg.ai.mcpServers.meeting;
      }).server;
  in
    assert lib.all (entry: entry.assertion) cfg.assertions;
    assert spec.headerSecrets == {};
    assert spec.fileHeaders == {"file_${builtins.hashString "sha256" "Authorization"}" = "${stateRoot}/mcp-oauth/${backend}/work/access-token";};
    assert spec.headers == {Authorization = "Bearer {vars.file_${builtins.hashString "sha256" "Authorization"}}";}; {
      clients = harness.claudeMcpServers backend evaluated;
      commands = lib.mapAttrs (_: service: service.command) proxyServices;
      restartPaths = lib.mapAttrs (_: service: service.restartOnChange) proxyServices;
      rootOwners = builtins.attrNames cfg.ai.internal.services;
      runtimeOwners = builtins.attrNames cfg.ai.claude.services;
      inherit stateRoot;
    };
  # These cases reject missing resolution, disabled account lookup, overrides
  # (including null), and checks placed only after the active-root filter.
  refused = [
    {ai.mcp-oauth.accounts.work.enable = false;}
    {ai.claude.mcpServers.messaging.proxy.headers.authorization = null;}
    {
      ai.claude.enable = lib.mkForce false;
      ai.mcpServers.meeting.proxy.headers.authorization = null;
    }
    {ai.mcpServers.meeting.proxy.oauthAccount = lib.mkForce "missing";}
    {ai.claude.mcpServers.messaging.proxy.oauthAccount = lib.mkForce "missing";}
    {ai.mcpServers.meeting.proxy.headers.aUtHoRiZaTiOn = "override";}
    {ai.mcpServers.meeting.proxy.headers.AUTHORIZATION = null;}
    {ai.mcpServers.meeting.proxy.host = "0.0.0.0";}
    {ai.mcpServers.meeting.proxy.enable = lib.mkForce false;}
    {
      ai.claude.enable = lib.mkForce false;
      ai.mcpServers.meeting.proxy.enable = lib.mkForce false;
    }
  ];
  accepts = backend: extra: let
    cfg = (evaluate backend extra).config;
  in
    (builtins.tryEval (builtins.deepSeq [cfg.ai.services (map (entry: entry.assertion) cfg.assertions)] true)).success;
  unsafeRoot = backend:
    if backend == "hm"
    then {xdg.stateHome = "/bad root";}
    else {devenv.state = "/bad root";};
  unused = (evaluate "hm" {ai.claude.enable = lib.mkForce false;}).config;
in {
  checks =
    lib.all (backend:
      accepts backend {}
      && lib.all (extra: !(accepts backend extra)) refused
      && !(accepts backend (unsafeRoot backend))) ["devenv" "hm"]
    && !(unused.ai.services ? mcp-proxy-meeting);
  snapshots = lib.genAttrs ["devenv" "hm"] snapshot;
}
