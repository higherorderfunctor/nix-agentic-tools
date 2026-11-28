# Factory and managed-service contracts for chrome-devtools-mcp.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) checkRows evalHm hmLib rejectsChange;
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  owner = import ../lib/extracted.nix {inherit lib;};
  mkChromeDevtools = import ../lib/mkChromeDevtools.nix;
  factory = mkChromeDevtools {
    lib = hmLib;
    pkgs = pkgs // {ai = (pkgs.ai or {}) // {mcpServers = ((pkgs.ai or {}).mcpServers or {}) // {chrome-devtools-mcp = pkgs.hello;};};};
  };
  settings = {
    backgroundNewPages = true;
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
    "--backgroundNewPages=true"
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
  name = "chrome-devtools-mcp";
  argsFor = input: (factory {settings = input;}).args;
  samples = {
    allowUnrestrictedPaths = true;
    allowedUrlPattern = ["https://example.org/*"];
    autoConnect = true;
    blockedUrlPattern = ["https://example.net/*"];
    browserUrl = "http://127.0.0.1:9222";
    categoryPwa = true;
    channel = "stable";
    inherit (settings) executablePath;
    isolated = true;
    inherit (settings) userDataDir;
    workspace = ["/run/examples/project"];
    wsEndpoint = "ws://127.0.0.1:9222/devtools/browser/id";
  };
  # Independent argv controls: each of the four ways to select a browser
  # must work alone before it can distinguish a forbidden pair.
  browserArgs = {
    autoConnect = ["--autoConnect=true"];
    browserUrl = ["--browserUrl=http://127.0.0.1:9222"];
    executablePath = ["--executablePath=/run/examples/chrome"];
    wsEndpoint = ["--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/id"];
  };
  browserControl = option: extra: expected: {
    valid = extra // {${option} = samples.${option};};
    inherit expected;
  };
  rejectsPair = control: forbidden:
    lib.nameValuePair "${control.label} conflicts with ${forbidden}" (rejectsChange argsFor {
      inherit (control) expected valid;
      invalid = control.valid // {${forbidden} = samples.${forbidden};};
    });
  configured = factory {inherit settings;};
  render = mcpLib.renderServer pkgs name;
  packageInput = mcpLib.mkStdioEntry {
    package = pkgs.hello;
    inherit settings;
  };
  packageEntry = render packageInput;
  bridgeFor = input:
    (evalHm {
      services.mcp-servers.servers.chrome-devtools-mcp = {enable = true;} // input;
    }).config;
  bridgeInput = {inherit settings;};
  bridge = bridgeFor bridgeInput;
  bridgeCommand = input: (bridgeFor input).ai.services.mcp-chrome-devtools-mcp.command;
  bridgeExpected =
    [
      (lib.getExe bridge.ai.internal.packages.mcpServers.mcp-proxy)
      "--pass-environment"
      "--host"
      "127.0.0.1"
      "--port"
      "19762"
      "--"
      "${bridge.services.mcp-servers.servers.chrome-devtools-mcp.package}/bin/chrome-devtools-mcp"
    ]
    ++ expectedArgs;
in {
  checks = {
    factory-chrome-devtools-mcp-bridge-command = mkTest "chrome-devtools-mcp-bridge-command" (
      let
        rejectsBridge = invalid:
          rejectsChange bridgeCommand {
            inherit invalid;
            valid = bridgeInput;
            # Positive control pins the loopback proxy and child argv together.
            expected = bridgeExpected;
          };
      in
        checkRows "managed bridge" {
          "does not bypass the conflict guard for isolated and userDataDir" = rejectsBridge {settings = settings // {isolated = true;};};
          "does not fall back to implicit Chrome discovery" = rejectsBridge {};
        }
    );

    # Pin the report categories too: an empty report must not hide new,
    # malformed, stale or mistyped option classifications and refinements.
    factory-chrome-devtools-mcp-classification-drift = mkTest "chrome-devtools-mcp-classification-drift" (
      owner.report
      == {
        malformedClassification = [];
        misplaced = [];
        staleClassification = [];
        staleExclusions = [];
        staleRefinements = [];
        unclassifiedOptions = [];
        unprovenRefinements = [];
        untyped = [];
      }
    );

    factory-chrome-devtools-mcp-conflicts = mkTest "chrome-devtools-mcp-conflicts" (
      let
        pairs = label: control: forbidden: map (rejectsPair (control // {inherit label;})) forbidden;
        browserPairs = option: forbidden:
          pairs option (browserControl option {} browserArgs.${option}) forbidden;
        executableWith = option: arg: forbidden:
          pairs option (browserControl "executablePath" {${option} = samples.${option};} arg) [forbidden];
        # A group interpreted as only its first pair would miss these rows.
        rows =
          executableWith "allowedUrlPattern" ["--allowedUrlPattern=https://example.org/*" "--executablePath=/run/examples/chrome"] "blockedUrlPattern"
          ++ browserPairs "autoConnect" ["categoryPwa" "executablePath" "isolated"]
          ++ browserPairs "browserUrl" ["categoryPwa" "channel" "executablePath" "userDataDir" "wsEndpoint"]
          ++ browserPairs "executablePath" ["channel"]
          ++ executableWith "userDataDir" ["--executablePath=/run/examples/chrome" "--userDataDir=/run/examples/browser-data"] "isolated"
          ++ executableWith "workspace" ["--executablePath=/run/examples/chrome" "--workspace=/run/examples/project"] "allowUnrestrictedPaths"
          ++ browserPairs "wsEndpoint" ["categoryPwa" "channel" "executablePath" "userDataDir"];
      in
        checkRows "factory conflicts" (builtins.listToAttrs rows
          // {
            # False does not participate in conflicts, but still renders.
            "false neither conflicts with a chosen browser nor disappears from argv" =
              argsFor {
                autoConnect = false;
                inherit (settings) executablePath;
                isolated = false;
              }
              == ["--autoConnect=false" "--executablePath=/run/examples/chrome" "--isolated=false"];
          })
    );

    # The package-backed entry the README documents renders the same argv.
    # Without a package there is nothing to run, so a settings-only entry is refused.
    factory-chrome-devtools-mcp-package-entry = mkTest "chrome-devtools-mcp-package-entry" (
      checkRows "package entry" {
        "does not lose the package executable or settings argv" =
          packageEntry.command == "${pkgs.hello}/bin/chrome-devtools-mcp" && packageEntry.args == expectedArgs;
        "rejects an entry without package, command or URL" = rejectsChange (input: (render input).type) {
          valid = packageInput;
          invalid = removeAttrs packageInput ["package"];
          expected = "stdio";
        };
      }
    );

    factory-chrome-devtools-mcp-refuses-invalid-values = mkTest "chrome-devtools-mcp-refuses-invalid-values" (
      let
        # Force only the typed setting that owns the restriction, not browser
        # choice or conflict logic in the argv renderer.
        rejectsValue = option: valid: invalid:
          rejectsChange (input: (mcpLib.evalSettings name input).${option}) {
            valid.${option} = valid;
            invalid.${option} = invalid;
            expected = valid;
          };
      in
        checkRows "typed settings" {
          "browserUrl rejects an empty URL" = rejectsValue "browserUrl" samples.browserUrl "";
          "executablePath rejects an empty path" = rejectsValue "executablePath" settings.executablePath "";
          # The image format does not affect browser choice or conflicts, so
          # this catches a factory that renders settings without validating them.
          "factory entry refuses a value only the typed merge rejects" = rejectsChange argsFor {
            valid = settings;
            invalid = settings // {screenshotFormat = "avif";};
            expected = expectedArgs;
          };
          "screenshotMaxWidth rejects zero" = rejectsValue "screenshotMaxWidth" 1280 0;
          "workspace rejects a list with a null member" = rejectsValue "workspace" settings.workspace [null];
          "workspace rejects an empty list that would render no flag" = rejectsValue "workspace" settings.workspace [];
          "wsEndpoint rejects a non-WebSocket URL" = rejectsValue "wsEndpoint" samples.wsEndpoint "http://127.0.0.1:9222";
        }
    );

    factory-chrome-devtools-mcp-required-argv = mkTest "chrome-devtools-mcp-required-argv" (
      checkRows "raw command entry" {
        "does not leak typed settings into the raw command entry" = configured.settings == {};
        "does not switch the installed command to a different transport" = configured.type == "stdio" && configured.command == name;
        "keeps scalar values, explicit false and both workspace arguments through rendering" = (render configured).args == expectedArgs;
      }
    );

    factory-chrome-devtools-mcp-requires-browser-choice = mkTest "chrome-devtools-mcp-requires-browser-choice" (
      let
        autoConnect = browserControl "autoConnect" {} browserArgs.autoConnect;
      in
        checkRows "explicit browser choice" {
          "false autoConnect does not select a browser" = rejectsChange argsFor (autoConnect // {invalid.autoConnect = false;});
          "omitting all choices does not trigger implicit lookup" = rejectsChange argsFor (autoConnect // {invalid = {};});
        }
    );
  };
}
