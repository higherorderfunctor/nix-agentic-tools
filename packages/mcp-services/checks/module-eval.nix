# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) checkRows evalHm launchdAgentRunsLauncher mkTest;

  defaultConfig = (evalHm {}).config.services.mcp-servers;
  serverNames = [
    "chrome-devtools-mcp"
    "context7-mcp"
    "effect-mcp"
    "git-intel-mcp"
    "github-mcp"
    "gitlab-mcp"
    "kagi-mcp"
    "nixos-mcp"
  ];

  twoManagedServers = context7Overrides:
    (evalHm {
      services.mcp-servers.servers = {
        context7-mcp = {enable = true;} // context7Overrides;
        effect-mcp.enable = true;
      };
    }).config;

  # tryEval cannot expose throw messages. Follow facet-mock-negative by
  # evaluating a subprocess and checking its stderr, with a passing control.
  # Read settings directly so a renderer-local throw cannot satisfy the checks.
  settingsCheck = name: server: rows: let
    source = lib.fileset.toSource {
      root = ../../..;
      fileset = lib.fileset.unions [
        ../../../lib/mcp.nix
        ../../../lib/open-keys
        ../../../lib/redact
        ../../../packages/git-intel-mcp/modules/mcp-server.nix
        ../../../packages/gitlab-mcp/modules/mcp-server.nix
      ];
    };
    probe = pkgs.writeText "${name}.nix" ''
      { row }:
      let
        lib = import ${pkgs.path}/lib;
        mcpLib = import ${source}/lib/mcp.nix { inherit lib; };
        case = (builtins.fromJSON ${builtins.toJSON (builtins.toJSON rows)}).''${row};
        result = mcpLib.evalSettings ${builtins.toJSON server} case.settings;
      in
        if case ? expected then
          let observed = if case.exact or false then result else builtins.intersectAttrs case.expected result;
          in builtins.deepSeq result (
            assert !(result ? assertions);
            assert observed == case.expected;
            true
          )
        else result
    '';
  in
    pkgs.runCommandLocal "module-test-${name}" {nativeBuildInputs = [pkgs.nix];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export USER="''${USER:-nixbld}"
      export NIX_STATE_DIR="$TMPDIR/nix-state"
      mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
      run_case() {
        echo "CASE: $1"
        nix-instantiate --eval --strict ${probe} --argstr row "$1"
      }
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (label: row: let
        argument = lib.escapeShellArg label;
      in
        if row ? expected
        then "run_case ${argument}"
        else ''
          if run_case ${argument} 2>actual.stderr; then
            echo "FAIL: expected a settings assertion failure" >&2
            exit 1
          fi
          ${lib.concatMapStringsSep "\n" (message: ''
            if ! grep -F -- ${lib.escapeShellArg message} actual.stderr; then
              cat actual.stderr >&2
              exit 1
            fi
          '') (["MCP server ${server} settings assertions failed:"] ++ row.required)}
          ${lib.concatMapStringsSep "\n" (message: ''
            if grep -F -- ${lib.escapeShellArg message} actual.stderr; then
              echo "FAIL: diagnostic includes a passing assertion" >&2
              exit 1
            fi
          '') (row.forbidden or [])}
        '')
      rows)}
      echo "PASS: ${name}" > "$out"
    '';

  gitlabInstance = "https://gitlab.example.com";
  gitlabMutexMessage = "gitlab-mcp: settings.instanceUrl and settings.apiUrl are mutually exclusive";
  gitlabControl = settings: expected: {inherit expected settings;};
  gitlabConflict = apiUrl: {
    required = [gitlabMutexMessage];
    settings = {
      inherit apiUrl;
      instanceUrl = gitlabInstance;
    };
  };
  gitlabReferencePath = "/run/secrets/gitlab-url";
  gitlabCommand = redact.command gitlabReferencePath;
  gitlabFile = redact.file gitlabReferencePath;

  assertionSettings = passing: {
    assertions = [
      {
        assertion = true;
        message = "passing assertion must not appear";
      }
      {
        assertion = passing;
        message = "first caller assertion failed";
      }
      {
        assertion = passing;
        message = "second caller assertion failed";
      }
    ];
  };
in {
  checks =
    {
      module-mcp-gitlab-settings-mutex = settingsCheck "mcp-gitlab-settings-mutex" "gitlab-mcp" {
        "a passing endpoint assertion cannot mask the caller failure" = {
          forbidden = [gitlabMutexMessage];
          required = ["gitlab caller assertion failed"];
          settings.assertions = [
            {
              assertion = false;
              message = "gitlab caller assertion failed";
            }
          ];
        };
        "command reference alone survives settings evaluation" = gitlabControl {apiUrl = gitlabCommand;} {
          apiUrl = gitlabCommand;
          instanceUrl = null;
        };
        "command reference cannot bypass the endpoint mutex" = gitlabConflict gitlabCommand;
        "file reference alone survives settings evaluation" = gitlabControl {apiUrl = gitlabFile;} {
          apiUrl = gitlabFile;
          instanceUrl = null;
        };
        "file reference cannot bypass the endpoint mutex" = gitlabConflict gitlabFile;
        "public instance URL works without a reference" = gitlabControl {instanceUrl = gitlabInstance;} {
          apiUrl = null;
          instanceUrl = gitlabInstance;
        };
      };

      # The bridge owns the listener; its stdio child must not receive HTTP args.
      module-mcp-services-bridge-pins-bind-host = mkTest "mcp-services-bridge-pins-bind-host" (let
        bridgeCase = serverOverrides: expectedHost: let
          result = evalHm {
            services.mcp-servers.servers.context7-mcp =
              {
                args = ["--extra"];
                enable = true;
              }
              // serverOverrides;
          };
          inherit (result.config) ai services;
          server = services.mcp-servers.servers.context7-mcp;
        in
          ai.services.mcp-context7-mcp.command
          == [
            (lib.getExe ai.internal.packages.mcpServers.mcp-proxy)
            "--pass-environment"
            "--host"
            expectedHost
            "--port"
            "19750"
            "--"
            "${server.package}/bin/context7-mcp"
            "--transport"
            "stdio"
            "--extra"
          ]
          && services.mcp-servers.mcpConfig.mcpServers.context7-mcp.url == "http://${expectedHost}:19750/mcp";
      in
        checkRows "managed MCP bridge listener and client URL" {
          "a host override reaches both the proxy and the client" = bridgeCase {service.host = "127.0.0.2";} "127.0.0.2";
          "omitting the host keeps both proxy and client on loopback" = bridgeCase {} "127.0.0.1";
        });

      module-mcp-services-native-command = mkTest "mcp-services-native-command" (let
        result = evalHm {
          services.mcp-servers.servers.nixos-mcp = {
            enable = true;
            service.host = "127.0.0.2";
          };
        };
        service = result.config.ai.services.mcp-nixos-mcp;
        server = result.config.services.mcp-servers.servers.nixos-mcp;
      in
        checkRows "managed MCP native listener" {
          "client uses the native listener override and MCP path" = result.config.services.mcp-servers.mcpConfig.mcpServers.nixos-mcp.url == "http://127.0.0.2:19752/mcp";
          "daemon receives host, port and HTTP mode through its environment" =
            service.environment
            == {
              MCP_NIXOS_HOST = "127.0.0.2";
              MCP_NIXOS_PORT = "19752";
              MCP_NIXOS_TRANSPORT = "http";
            };
          "native daemon launches directly without a bridge" = service.command == ["${server.package}/bin/mcp-nixos"];
        });

      module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (checkRows "default MCP server registry" {
        "clients receive no endpoints before a server is enabled" = defaultConfig.mcpConfig.mcpServers == {};
        "disabled servers cannot advertise tools to auto-approval consumers" = defaultConfig.tools == {};
        "registration neither loses a supported server nor exposes an unexpected one" = builtins.attrNames defaultConfig.servers == serverNames;
      });

      module-mcp-services-port-collision = mkTest "mcp-services-port-collision" (let
        failureMessages = config: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) config.assertions);
      in
        checkRows "managed MCP port claims" {
          "matching ports identify both daemon claims" =
            failureMessages (twoManagedServers {service.port = 19754;})
            == ["ai.claims.port.19754: claimed by mcp-services:mcp-context7-mcp.ports.main and mcp-services:mcp-effect-mcp.ports.main"];
        });

      module-mcp-settings-assertion-messages = settingsCheck "mcp-settings-assertion-messages" "git-intel-mcp" {
        "all passing assertions leave only the settings payload" = {
          exact = true;
          expected.repository = null;
          settings = assertionSettings true;
        };
        "failure reports both caller messages and omits the passing one" = {
          forbidden = ["passing assertion must not appear"];
          required = ["first caller assertion failed" "second caller assertion failed"];
          settings = assertionSettings false;
        };
      };
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      module-mcp-services-owner-forwarding = mkTest "mcp-services-owner-forwarding" (let
        secretPath = "/run/secrets/gh-token";
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials = redact.file secretPath;
          };
        };
        inherit (result) config;
        service = config.ai.services.mcp-github-mcp;
        unit = config.systemd.user.services.mcp-github-mcp;
      in
        checkRows "managed GitHub MCP service forwarding" {
          "credential remains a launcher reference under the upstream variable" = service.environment == {GITHUB_PERSONAL_ACCESS_TOKEN = redact.file secretPath;};
          "forwarding does not drop owner service fields" = service == config.ai.mcp-services.services.mcp-github-mcp;
          "port claims keep the daemon and named port attribution" = config.ai.claims.port."19751" == ["mcp-services:mcp-github-mcp.ports.main"];
          "systemd launches via the secret-resolving launcher" = lib.hasSuffix "/bin/ai-service-mcp-github-mcp" unit.Service.ExecStart;
        });
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Fails when a server's service is missing from launchd or runs something other than its launcher.
      module-mcp-services-darwin-launchd = mkTest "mcp-services-darwin-launchd" (let
        config = twoManagedServers {};
      in
        checkRows "managed MCP services on Darwin" {
          "context7-mcp uses its launchd launcher" = launchdAgentRunsLauncher config "mcp-context7-mcp";
          "effect-mcp also uses its own launcher when enabled alongside context7-mcp" = launchdAgentRunsLauncher config "mcp-effect-mcp";
        });
    };
}
