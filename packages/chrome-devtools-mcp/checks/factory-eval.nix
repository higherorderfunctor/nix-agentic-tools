# Factory and managed-service contracts for chrome-devtools-mcp.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) evalHm hmLib;
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  owner = import ../lib/extracted.nix {inherit lib;};
  mkChromeDevtools = import ../lib/mkChromeDevtools.nix;
  factory = mkChromeDevtools {
    lib = hmLib;
    pkgs = pkgs // {ai = (pkgs.ai or {}) // {mcpServers = ((pkgs.ai or {}).mcpServers or {}) // {chrome-devtools-mcp = pkgs.hello;};};};
  };
  settings = {
    executablePath = "/run/examples/chrome";
    performanceCrux = false;
    redactNetworkHeaders = true;
    screenshotFormat = "jpeg";
    screenshotMaxWidth = 1280;
    usageStatistics = false;
    userDataDir = "/run/examples/browser-data";
    workspace = ["/run/examples/project" "/run/examples/documents"];
  };
  expectedArgs = [
    "--executablePath=/run/examples/chrome"
    "--performanceCrux=false"
    "--redactNetworkHeaders=true"
    "--screenshotFormat=jpeg"
    "--screenshotMaxWidth=1280"
    "--usageStatistics=false"
    "--userDataDir=/run/examples/browser-data"
    "--workspace=/run/examples/project"
    "--workspace=/run/examples/documents"
  ];
  configured = factory {inherit settings;};
  rendered = mcpLib.renderServer pkgs "chrome-devtools-mcp" configured;
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  bridge = evalHm {
    services.mcp-servers.servers.chrome-devtools-mcp = {
      enable = true;
      inherit settings;
    };
  };
  unchosenBridge = evalHm {
    services.mcp-servers.servers.chrome-devtools-mcp.enable = true;
  };
  bridgeService = bridge.config.ai.services.mcp-chrome-devtools-mcp;
  bridgeServer = bridge.config.services.mcp-servers.servers.chrome-devtools-mcp;
  bridgeProxyPrefix = lib.take 7 bridgeService.command;
in {
  checks = {
    factory-chrome-devtools-mcp-required-argv = mkTest "chrome-devtools-mcp-required-argv" (
      configured.type
      == "stdio"
      && configured.command == "chrome-devtools-mcp"
      && configured.settings == {}
      && configured.args == expectedArgs
      && rendered.args == expectedArgs
    );

    factory-chrome-devtools-mcp-refuses-invalid-values = mkTest "chrome-devtools-mcp-refuses-invalid-values" (
      # Each case changes one value of the valid settings, so the browser
      # choice cannot be what refuses it.
      throws (factory {settings = settings // {screenshotFormat = "avif";};})
      && throws (factory {settings = settings // {screenshotMaxWidth = 0;};})
      && throws (factory {settings = settings // {workspace = [];};})
      && throws (factory {settings = settings // {workspace = [null];};})
    );

    factory-chrome-devtools-mcp-requires-browser-choice = mkTest "chrome-devtools-mcp-requires-browser-choice" (
      throws (factory {settings = {};})
      && throws (factory {settings.autoConnect = false;})
      && (factory {settings.browserUrl = "http://127.0.0.1:9222";}).args == ["--browserUrl=http://127.0.0.1:9222"]
      && (factory {settings.autoConnect = true;}).args == ["--autoConnect=true"]
      && (factory {settings.wsEndpoint = "ws://127.0.0.1:9222/devtools/browser/id";}).args == ["--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/id"]
      # An empty or malformed choice is not a choice.
      && throws (factory {settings.browserUrl = "";})
      && throws (factory {settings.executablePath = "";})
      && throws (factory {settings.wsEndpoint = "http://127.0.0.1:9222";})
      # The managed bridge renders through the same settings.
      && throws unchosenBridge.config.ai.services.mcp-chrome-devtools-mcp.command
    );

    factory-chrome-devtools-mcp-bridge-command = mkTest "chrome-devtools-mcp-bridge-command" (
      bridgeProxyPrefix
      == [
        (lib.getExe bridge.config.ai.internal.packages.mcpServers.mcp-proxy)
        "--pass-environment"
        "--host"
        "127.0.0.1"
        "--port"
        "19762"
        "--"
      ]
      && lib.drop 7 bridgeService.command
      == ["${bridgeServer.package}/bin/chrome-devtools-mcp"] ++ expectedArgs
    );

    factory-chrome-devtools-mcp-classification-drift = mkTest "chrome-devtools-mcp-classification-drift" (
      lib.all (list: list == []) (builtins.attrValues owner.report)
    );
  };
}
