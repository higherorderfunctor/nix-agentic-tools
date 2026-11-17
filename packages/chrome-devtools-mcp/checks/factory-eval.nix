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
  # Every row starts from independently rendered valid settings. Each addition
  # changes one setting, covering every pair in upstream's multi-option groups.
  conflictCases = let
    case = valid: expected: additions: {inherit additions expected valid;};
  in [
    (case {
        allowedUrlPattern = ["https://example.org/*"];
        executablePath = "/run/examples/chrome";
      }
      ["--allowedUrlPattern=https://example.org/*" "--executablePath=/run/examples/chrome"]
      [{blockedUrlPattern = ["https://example.net/*"];}])
    (case {autoConnect = true;} ["--autoConnect=true"] [
      {categoryPwa = true;}
      {executablePath = "/run/examples/chrome";}
      {isolated = true;}
    ])
    (case {browserUrl = "http://127.0.0.1:9222";} ["--browserUrl=http://127.0.0.1:9222"] [
      {categoryPwa = true;}
      {channel = "stable";}
      {executablePath = "/run/examples/chrome";}
      {userDataDir = "/run/examples/browser-data";}
      {wsEndpoint = "ws://127.0.0.1:9222/devtools/browser/id";}
    ])
    (case {executablePath = "/run/examples/chrome";} ["--executablePath=/run/examples/chrome"] [{channel = "stable";}])
    (case {
        executablePath = "/run/examples/chrome";
        userDataDir = "/run/examples/browser-data";
      }
      ["--executablePath=/run/examples/chrome" "--userDataDir=/run/examples/browser-data"]
      [{isolated = true;}])
    (case {
        executablePath = "/run/examples/chrome";
        workspace = ["/run/examples/project"];
      }
      ["--executablePath=/run/examples/chrome" "--workspace=/run/examples/project"]
      [{allowUnrestrictedPaths = true;}])
    (case {wsEndpoint = "ws://127.0.0.1:9222/devtools/browser/id";} ["--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/id"] [
      {categoryPwa = true;}
      {channel = "stable";}
      {executablePath = "/run/examples/chrome";}
      {userDataDir = "/run/examples/browser-data";}
    ])
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
    factory-chrome-devtools-mcp-conflicts = mkTest "chrome-devtools-mcp-conflicts" (
      lib.all (test:
        (factory {settings = test.valid;}).args
        == test.expected
        && lib.all (addition: throws (factory {settings = test.valid // addition;}).args) test.additions)
      conflictCases
      # False and null do not participate, but explicit false still renders.
      && lib.all (test:
        (factory {
          settings =
            settings
            // {
              autoConnect = test.value;
              isolated = test.value;
            };
        }).args
        == test.expected) [
        {
          expected = [
            "--autoConnect=false"
            "--executablePath=/run/examples/chrome"
            "--isolated=false"
            "--performanceCrux=false"
            "--redactNetworkHeaders=true"
            "--screenshotFormat=jpeg"
            "--screenshotMaxWidth=1280"
            "--usageStatistics=false"
            "--userDataDir=/run/examples/browser-data"
            "--workspace=/run/examples/project"
            "--workspace=/run/examples/documents"
          ];
          value = false;
        }
        {
          expected = expectedArgs;
          value = null;
        }
      ]
      && throws
      (evalHm {
        services.mcp-servers.servers.chrome-devtools-mcp = {
          enable = true;
          settings = settings // {isolated = true;};
        };
      }).config.ai.services.mcp-chrome-devtools-mcp.command
    );

    # The package-backed entry the README documents: the module renders the
    # same argv and carries the stdio timeout. Without a package there is
    # nothing to run, so a settings-only entry is refused.
    factory-chrome-devtools-mcp-package-entry = mkTest "chrome-devtools-mcp-package-entry" (
      let
        entry = mcpLib.renderServer pkgs "chrome-devtools-mcp" (mcpLib.mkStdioEntry {
          package = pkgs.hello;
          inherit settings;
          timeout = 300000;
        });
      in
        entry.type
        == "stdio"
        && entry.command == "${pkgs.hello}/bin/chrome-devtools-mcp"
        && entry.args == expectedArgs
        && entry.timeout == 300000
        && throws (mcpLib.renderServer pkgs "chrome-devtools-mcp" {inherit settings;})
    );

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
