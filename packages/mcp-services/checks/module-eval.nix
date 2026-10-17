# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) evalHm mcpLib mkTest;

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
  expectedSettings = {
    repository = null;
  };
in {
  checks = {
    # Evaluate settings directly so a renderer-local throw cannot satisfy this test.
    module-mcp-gitlab-settings-mutex = let
      source = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.unions [
          ../../../lib/mcp.nix
          ../../../lib/open-keys
          ../../../lib/redact
          ../../../packages/gitlab-mcp/modules/mcp-server.nix
        ];
      };
      probe = pkgs.writeText "gitlab-settings-mutex.nix" ''
        { credential ? "none", instance ? false, callerPassing ? true }:
        let
          lib = import ${pkgs.path}/lib;
          mcpLib = import ${source}/lib/mcp.nix { inherit lib; };
          redact = import ${source}/lib/redact { inherit lib; };
          settings = {
            assertions = [{ assertion = callerPassing; message = "gitlab caller assertion failed"; }];
            instanceUrl = if instance then "https://gitlab.example.com" else null;
          } // lib.optionalAttrs (credential != "none") {
            apiUrl = if credential == "file" then redact.file "/run/secrets/gitlab-url" else redact.command "/run/secrets/gitlab-url";
          };
          result = mcpLib.evalSettings "gitlab-mcp" settings;
        in
          builtins.deepSeq result (
            assert !(result ? assertions);
            assert result.instanceUrl == settings.instanceUrl;
            assert credential == "none" || result.apiUrl == settings.apiUrl;
            true
          )
      '';
    in
      pkgs.runCommandLocal "module-test-mcp-gitlab-settings-mutex" {
        nativeBuildInputs = [pkgs.nix];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export USER="''${USER:-nixbld}"
        export NIX_STATE_DIR="$TMPDIR/nix-state"
        mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
        for credential in none file command; do
          nix-instantiate --eval --strict ${probe} --argstr credential "$credential"
        done
        nix-instantiate --eval --strict ${probe} --arg instance true
        for credential in file command; do
          if nix-instantiate --eval --strict ${probe} --argstr credential "$credential" --arg instance true >actual.stdout 2>actual.stderr; then
            echo "FAIL: gitlab instanceUrl + apiUrl.$credential unexpectedly succeeded" >&2
            exit 1
          fi
          grep -F 'MCP server gitlab-mcp settings assertions failed:' actual.stderr
          grep -F 'settings.instanceUrl and settings.apiUrl are mutually exclusive' actual.stderr
        done
        # The server's passing assertion must not hide a failing caller assertion.
        if nix-instantiate --eval --strict ${probe} --arg callerPassing false >actual.stdout 2>actual.stderr; then
          echo "FAIL: gitlab caller assertion unexpectedly succeeded" >&2
          exit 1
        fi
        grep -F 'gitlab caller assertion failed' actual.stderr
        if grep -F 'mutually exclusive' actual.stderr; then
          echo "FAIL: diagnostic includes a passing server assertion" >&2
          exit 1
        fi
        echo "PASS: gitlab mutex rejects file/command conflicts; valid settings and caller assertions verified" | tee "$out"
      '';

    # tryEval cannot expose throw messages. Follow facet-mock-negative by
    # evaluating a subprocess and checking its stderr, with a passing control.
    module-mcp-settings-assertion-messages = let
      source = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.unions [
          ../../../lib/mcp.nix
          ../../../packages/git-intel-mcp/modules/mcp-server.nix
        ];
      };
      probe = pkgs.writeText "mcp-settings-assertions.nix" ''
        { passing ? false }:
        let
          lib = import ${pkgs.path}/lib;
          mcpLib = import ${source}/lib/mcp.nix { inherit lib; };
          settings = builtins.fromJSON (
            if passing
            then ${builtins.toJSON (builtins.toJSON (assertionSettings true))}
            else ${builtins.toJSON (builtins.toJSON (assertionSettings false))}
          );
          result = mcpLib.evalSettings "git-intel-mcp" settings;
        in
          if passing
          then assert result == builtins.fromJSON ${builtins.toJSON (builtins.toJSON expectedSettings)}; true
          else result
      '';
    in
      pkgs.runCommandLocal "module-test-mcp-settings-assertion-messages" {
        nativeBuildInputs = [pkgs.nix];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export USER="''${USER:-nixbld}"
        export NIX_STATE_DIR="$TMPDIR/nix-state"
        mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
        nix-instantiate --eval --strict ${probe} --arg passing true
        if nix-instantiate --eval --strict ${probe} --arg passing false >actual.stdout 2>actual.stderr; then
          echo "FAIL: failing MCP assertions unexpectedly succeeded" >&2
          exit 1
        fi
        ${lib.concatMapStringsSep "\n" (message: ''
          if ! grep -F -- ${lib.escapeShellArg message} actual.stderr; then
            cat actual.stderr >&2
            exit 1
          fi
        '') (["MCP server git-intel-mcp settings assertions failed:"] ++ map (entry: entry.message) (builtins.filter (entry: !entry.assertion) (assertionSettings false).assertions))}
        if grep -F -- "passing assertion must not appear" actual.stderr; then
          echo "FAIL: diagnostic includes a passing assertion" >&2
          exit 1
        fi
        echo "PASS: MCP assertion diagnostics contain both failing messages" > "$out"
      '';

    # Exercise the same settings in both arms; equality also rejects leaked metadata.
    module-mcp-settings-assertions = mkTest "mcp-settings-assertions" (
      let
        passing = builtins.tryEval (mcpLib.evalSettings "git-intel-mcp" (assertionSettings true) == expectedSettings);
        failing = builtins.tryEval (builtins.deepSeq (mcpLib.evalSettings "git-intel-mcp" (assertionSettings false)) true);
      in
        passing.success && passing.value && !failing.success
    );

    # ── services.mcp-servers module ──────────────────────────────────

    module-mcp-services-owner-forwarding = mkTest "mcp-services-owner-forwarding" (
      let
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials = redact.file "/run/secrets/gh-token";
          };
        };
        inherit (result) config;
        service = config.ai.services.mcp-github-mcp;
        unit = config.systemd.user.services.mcp-github-mcp;
        services = import ../../ai-module/lib/services.nix {inherit lib;};
      in
        service
        == config.ai.mcp-services.services.mcp-github-mcp
        && service.environment
        == {
          GITHUB_PERSONAL_ACCESS_TOKEN = redact.file "/run/secrets/gh-token";
        }
        && services.triggers service == ["/run/secrets/gh-token"]
        && service.restart == "on-failure"
        && config.ai.claims.port."19751" == ["mcp-services:mcp-github-mcp.ports.main"]
        && config.ai.claims.service.mcp-github-mcp == ["mcp-services"]
        && (!pkgs.stdenv.hostPlatform.isLinux
          || (
            lib.hasSuffix "/bin/ai-service-mcp-github-mcp" unit.Service.ExecStart
            && unit.Unit.Description == "mcp-github-mcp (ai.services)"
            && !(unit.Service ? Environment)
          ))
    );

    # The bridge owns the listener; its stdio child must not receive HTTP args.
    module-mcp-services-bridge-pins-bind-host = mkTest "mcp-services-bridge-pins-bind-host" (
      lib.all (
        host: let
          result = evalHm {
            services.mcp-servers.servers.context7-mcp =
              {
                enable = true;
                args = ["--extra"];
              }
              // lib.optionalAttrs (host != "127.0.0.1") {service.host = host;};
          };
          service = result.config.ai.services.mcp-context7-mcp;
          server = result.config.services.mcp-servers.servers.context7-mcp;
        in
          service.command
          == [
            (lib.getExe result.config.ai.internal.packages.mcpServers.mcp-proxy)
            "--pass-environment"
            "--host"
            host
            "--port"
            "19750"
            "--"
            "${server.package}/bin/context7-mcp"
            "--transport"
            "stdio"
            "--extra"
          ]
          && result.config.services.mcp-servers.mcpConfig.mcpServers.context7-mcp.url == "http://${host}:19750/mcp"
      ) ["127.0.0.1" "127.0.0.2"]
    );

    module-mcp-services-darwin-warns = mkTest "mcp-services-darwin-warns" (
      let
        result =
          harness.evalHmWithSpecialArgs {
            pkgs =
              pkgs
              // {
                stdenv =
                  pkgs.stdenv
                  // {
                    hostPlatform =
                      pkgs.stdenv.hostPlatform
                      // {
                        isDarwin = true;
                        isLinux = false;
                      };
                  };
              };
          } {
            services.mcp-servers.servers = {
              context7-mcp.enable = true;
              effect-mcp.enable = true;
            };
          };
      in
        result.config.systemd.user.services
        == {}
        && lib.all (name:
          builtins.elem
          "ai.services.mcp-${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written"
          result.config.warnings) ["context7-mcp" "effect-mcp"]
    );

    # Default: all servers are disabled.
    module-mcp-services-default-disabled = mkTest "mcp-services-default-disabled" (
      let
        result = evalHm {};
        inherit (result.config.services.mcp-servers) servers;
      in
        !(servers.context7-mcp.enable or true)
        && !(servers.github-mcp.enable or true)
        && !(servers.kagi-mcp.enable or true)
    );

    # mcpConfig output is empty when no servers enabled.
    module-mcp-services-mcpconfig-empty-when-disabled = mkTest "mcp-services-mcpconfig-empty-when-disabled" (
      let
        result = evalHm {};
      in
        result.config.services.mcp-servers.mcpConfig.mcpServers == {}
    );

    module-mcp-services-native-command = mkTest "mcp-services-native-command" (
      let
        result = evalHm {
          services.mcp-servers.servers.nixos-mcp = {
            enable = true;
            service.host = "127.0.0.2";
          };
        };
        service = result.config.ai.services.mcp-nixos-mcp;
        server = result.config.services.mcp-servers.servers.nixos-mcp;
      in
        service.command
        == ["${server.package}/bin/mcp-nixos"]
        && service.environment
        == {
          MCP_NIXOS_HOST = "127.0.0.2";
          MCP_NIXOS_PORT = "19752";
          MCP_NIXOS_TRANSPORT = "http";
        }
        && result.config.services.mcp-servers.mcpConfig.mcpServers.nixos-mcp.url == "http://127.0.0.2:19752/mcp"
    );

    # Server option tree has expected structure.
    module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (
      let
        result = evalHm {};
        inherit (result.config.services.mcp-servers) servers;
      in
        servers ? context7-mcp
        && servers ? effect-mcp
        && servers ? git-intel-mcp
        && servers ? github-mcp
        && servers ? gitlab-mcp
        && servers ? kagi-mcp
        && servers ? nixos-mcp
    );

    module-mcp-services-port-collision = mkTest "mcp-services-port-collision" (
      let
        result = evalHm {
          services.mcp-servers.servers = {
            context7-mcp = {
              enable = true;
              service.port = 19754;
            };
            effect-mcp.enable = true;
          };
        };
      in
        map (entry: entry.message) (builtins.filter (entry: !entry.assertion) result.config.assertions)
        == ["ai.claims.port.19754: claimed by mcp-services:mcp-context7-mcp.ports.main and mcp-services:mcp-effect-mcp.ports.main"]
    );

    # tools output is empty when no servers enabled.
    module-mcp-services-tools-empty-when-disabled = mkTest "mcp-services-tools-empty-when-disabled" (
      let
        result = evalHm {};
      in
        result.config.services.mcp-servers.tools == {}
    );
  };
}
