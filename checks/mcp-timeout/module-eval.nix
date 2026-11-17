# Test the files clients receive, including Kiro's activation template.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeMcpServers evalDevenv evalHm mcpLib mkTest setEnable;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib;}) hmCodexSettings;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  entries = {
    nixos-mcp = mcpLib.mkStdioEntry {
      package = pkgs.hello;
      timeout = 1501;
    };
    raw = {
      command = "probe";
      timeout = 1501;
    };
  };
  evaluate = backend: runtime: extra:
    backends.${backend} (lib.recursiveUpdate
      (lib.recursiveUpdate (setEnable runtime true) {ai.mcpServers = entries;})
      extra);
  timeoutWarnings = ev: builtins.filter (lib.hasInfix ".timeout is set but") ev.config.warnings;
  # Only the unrelated package command/env is reused. Timeout expectations below
  # are literals, so losing or mis-converting either stdio branch fails.
  withoutTimeout = servers:
    lib.mapAttrs (name: server:
      removeAttrs (mcpLib.renderServer pkgs name server) ["timeout"])
    servers;
  expected = runtime: servers: value:
    lib.mapAttrs (_: server:
      (
        if runtime == "codex"
        then lib.filterAttrs (_: value: value != {}) (removeAttrs server ["type"])
        else server
      )
      // (
        if value == null
        then {}
        else if runtime == "codex"
        then {tool_timeout_sec = value;}
        else if runtime == "kimchi"
        then {requestTimeoutMs = value;}
        else {timeout = value;}
      )) (withoutTimeout servers);
  matches = backend: runtime: ev: wanted:
    if runtime == "kiro"
    then let
      # Compare the actual content.run template reference, without IFD or
      # simulating timers. A changed native key changes this store path.
      template = pkgs.writeText "kiro-mcp.json" (builtins.toJSON {mcpServers = wanted;});
      script = ev.config.ai.kiro.files."${ev.config.ai.kiro.configDir}/settings/mcp.json".content.run;
    in
      lib.hasInfix (builtins.unsafeDiscardStringContext "${pkgs.coreutils}/bin/cat ${template}") script
    else
      (
        if runtime == "claude"
        then claudeMcpServers backend ev
        else if runtime == "codex"
        then (hmCodexSettings ev).mcp_servers
        else
          ev.config.ai.kimchi.files."${
            if backend == "hm"
            then ".config/kimchi/harness"
            else ".kimchi"
          }/mcp.json".content.value.mcpServers
      )
      == wanted;
  perBackend = name: test:
    lib.mapAttrs' (backend: _:
      lib.nameValuePair "module-mcp-timeout-${name}-${backend}"
      (mkTest "mcp-timeout-${name}-${backend}" (test backend)))
    backends;
  # Null keeps the old shape; HTTP must not be routed through stdio conversion.
  direct = {
    module-mcp-timeout-direct = mkTest "mcp-timeout-direct" (
      (mcpLib.renderServer pkgs "raw" entries.raw).timeout
      == 1501
      && (mcpLib.renderServer pkgs "nixos-mcp" entries.nixos-mcp).timeout == 1501
      && !(mcpLib.mkStdioEntry {package = pkgs.hello;} ? timeout)
      && !(mcpLib.renderServer pkgs "nixos-mcp" (mcpLib.mkStdioEntry {package = pkgs.hello;}) ? timeout)
      && mcpLib.renderServer pkgs "remote" {
        url = "https://example.test/mcp";
        timeout = 1501;
      }
      == {
        type = "http";
        url = "https://example.test/mcp";
        timeout = 1501;
      }
    );
    # Reject zero/negative at the common schema, before a runtime renderer.
    module-mcp-timeout-domain = mkTest "mcp-timeout-domain" (let
      timeoutType = (import ../../lib/ai/mcpServer/commonSchema.nix {inherit lib;}).options.timeout.type;
    in
      timeoutType.check null
      && timeoutType.check 1
      && !timeoutType.check 0
      && !timeoutType.check (-1));
  };
in {
  checks = lib.mkMerge (
    [direct]
    ++ map (runtime:
      perBackend runtime (backend: let
        ev = evaluate backend runtime {};
      in
        # Exact output rejects generic timeout leakage and startup_timeout_sec.
        matches backend runtime ev (expected runtime entries (
          if runtime == "codex"
          then 1.501
          else 1501
        ))
        && timeoutWarnings ev == []))
    runtimes
    ++ map (runtime:
      perBackend "${runtime}-overrides" (backend: let
        ev = evaluate backend runtime {
          ai.${runtime}.mcpServers = {
            nixos-mcp = null;
            raw = {
              command = "override";
              timeout = null;
            };
          };
        };
      in
        # Runtime entries replace shared entries, and null suppresses a server
        # or timeout instead of resurrecting the shared value.
        matches backend runtime ev (expected runtime {raw.command = "override";} null)
        && timeoutWarnings ev == []))
    runtimes
    ++ map (runtime:
      perBackend "${runtime}-override-value" (backend: let
        ev = evaluate backend runtime {
          ai.${runtime}.mcpServers.raw = {
            command = "override";
            timeout = 2501;
          };
        };
        wanted = expected runtime entries (
          if runtime == "codex"
          then 1.501
          else 1501
        );
        replacement = expected runtime {raw.command = "override";} (
          if runtime == "codex"
          then 2.501
          else 2501
        );
      in
        # A runtime timeout replaces the shared value instead of losing to it.
        matches backend runtime ev (wanted // replacement)
        && timeoutWarnings ev == []))
    runtimes
    ++ [
      (perBackend "codex-native" (backend: let
        ev = evaluate backend "codex" {
          ai.mcpServers.raw.codex = {
            startupTimeoutSec = 7;
            toolTimeoutSec = 9;
          };
        };
        wanted = expected "codex" entries 1.501;
      in
        # Native tool timeout wins; generic timeout never changes startup.
        matches backend "codex" ev (wanted
          // {
            raw =
              wanted.raw
              // {
                startup_timeout_sec = 7;
                tool_timeout_sec = 9;
              };
          })))
      (perBackend "copilot" (backend: let
        ev = evaluate backend "copilot" {};
      in
        # github.com has no local MCP surface; retain its whole-pool warning.
        lib.any (lib.hasPrefix "ai.mcpServers is set but") ev.config.warnings))
      (perBackend "http" (backend:
        lib.all (
          runtime: let
            ev = backends.${backend} (lib.recursiveUpdate (setEnable runtime true) {
              ai.mcpServers.remote = {
                url = "https://example.test/mcp";
                timeout = 1501;
              };
            });
            server = {
              type = "http";
              url = "https://example.test/mcp";
              timeout = 1501;
            };
          in
            # Do not repair or translate the existing HTTP output in this change.
            matches backend runtime ev {
              remote =
                if runtime == "codex"
                then removeAttrs server ["type"]
                else server;
            }
        )
        runtimes))
    ]
    ++ map (case:
      perBackend "${case.runtime}-${toString case.value}" (
        backend: let
          ev = backends.${backend} (lib.recursiveUpdate (setEnable case.runtime true) {
            ai.mcpServers.raw = {
              command = "probe";
              timeout = case.value;
            };
          });
        in
          # Unsupported bounds must warn AND omit; supported boundaries do neither.
          matches backend case.runtime ev (expected case.runtime {raw.command = "probe";} case.rendered)
          && builtins.length (timeoutWarnings ev) == case.warnings
      )) [
      {
        rendered = null;
        runtime = "claude";
        value = 999;
        warnings = 1;
      }
      {
        rendered = 1000;
        runtime = "claude";
        value = 1000;
        warnings = 0;
      }
      {
        rendered = 2147483647;
        runtime = "kimchi";
        value = 2147483647;
        warnings = 0;
      }
      {
        rendered = null;
        runtime = "kimchi";
        value = 2147483648;
        warnings = 1;
      }
      {
        rendered = 600000;
        runtime = "kiro";
        value = 600000;
        warnings = 0;
      }
      {
        rendered = null;
        runtime = "kiro";
        value = 600001;
        warnings = 1;
      }
    ]
  );
}
