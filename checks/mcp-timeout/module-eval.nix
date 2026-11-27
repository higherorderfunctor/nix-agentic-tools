# Test the files clients receive, including Kiro's activation template.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows claudeMcpServers evalDevenv evalHm mcpLib mkTest rejectsChange setEnable;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib;}) hmCodexSettings;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  raw = {command = "probe";};
  packageEntry = extra: mcpLib.mkStdioEntry ({package = pkgs.hello;} // extra);
  packaged = packageEntry {};
  entries = {
    nixos-mcp = packageEntry {timeout = 1501;};
    raw = raw // {timeout = 1501;};
  };
  evaluate = backend: runtime: config:
    backends.${backend} (lib.recursiveUpdate (setEnable runtime true) config);
  timeoutWarnings = ev: builtins.filter (lib.hasInfix ".timeout is set but") ev.config.warnings;

  # Fixed fixture outputs; don't call the shared renderer to get expected files.
  rawStdio = runtime: command:
    {
      args = [];
      inherit command;
    }
    // lib.optionalAttrs (runtime != "codex") {
      env = {};
      type = "stdio";
    };
  packagedStdio = runtime:
    rawStdio runtime "${pkgs.hello}/bin/mcp-nixos"
    // {
      env = {
        PYTHONNOUSERSITE = "true";
        PYTHONPATH = "";
      };
    };
  http = {url = "https://example.test/mcp";};
  nativeTimeouts = {
    claude = {
      httpMs = 999;
      replacement.timeout = 2501;
      shared.timeout = 1501;
    };
    codex = {
      httpMs = 1501;
      replacement.tool_timeout_sec = 2.501;
      shared.tool_timeout_sec = 1.501;
    };
    kimchi = {
      httpMs = 2147483648;
      replacement.requestTimeoutMs = 2501;
      shared.requestTimeoutMs = 1501;
    };
    kiro = {
      httpMs = 600001;
      replacement.timeout = 2501;
      shared.timeout = 1501;
    };
  };
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
  checkDelivery = backend: runtime: config: wanted: warnings: let
    ev = evaluate backend runtime config;
  in
    matches backend runtime ev wanted && timeoutWarnings ev == warnings;
  deliveryRows = backend: runtime: native: let
    check = checkDelivery backend runtime;
    shared = {
      nixos-mcp = packagedStdio runtime // native.shared;
      raw = rawStdio runtime "probe" // native.shared;
    };
    withOverrides = servers: {
      ai = {
        mcpServers = entries;
        ${runtime}.mcpServers = servers;
      };
    };
    # Use HTTP values outside the stdio bounds where the runtime has one.
    remote = http // {timeout = native.httpMs;};
  in
    checkRows "${backend}/${runtime} timeout delivery" ({
        "HTTP preserves milliseconds without stdio conversion or bounds" = check {ai.mcpServers = {inherit remote;};} {
          remote = remote // lib.optionalAttrs (runtime != "codex") {type = "http";};
        } [];
        "runtime timeout replaces the shared value" = check (withOverrides {
          raw = {
            command = "override";
            timeout = 2501;
          };
        }) (shared // {raw = rawStdio runtime "override" // native.replacement;}) [];
        # Runtime entries replace shared entries, and null suppresses a server
        # or timeout instead of resurrecting the shared value.
        "runtime tombstone and null timeout suppress the inherited values" = check (withOverrides {
          nixos-mcp = null;
          raw = {
            command = "override";
            timeout = null;
          };
        }) {raw = rawStdio runtime "override";} [];
        # Exact output rejects generic timeout leakage and startup_timeout_sec.
        "shared raw and packaged servers use the native timeout field" =
          check {ai.mcpServers = entries;} shared [];
      }
      // lib.optionalAttrs (runtime == "codex") {
        # Native tool timeout wins; generic timeout never changes startup.
        "native tool timeout wins and startup remains independent" =
          check {
            ai.mcpServers = lib.recursiveUpdate entries {
              raw.codex = {
                startupTimeoutSec = 7;
                toolTimeoutSec = 9;
              };
            };
          } (shared
            // {
              raw =
                rawStdio runtime "probe"
                // {
                  startup_timeout_sec = 7;
                  tool_timeout_sec = 9;
                };
            }) [];
      });
  bounds = {
    claude = {
      accepted.timeout = 1000;
      invalid = 999;
      reason = "Claude ignores per-server timeouts below 1000 ms; the timeout is omitted.";
      valid = 1000;
    };
    kimchi = {
      accepted.requestTimeoutMs = 2147483647;
      invalid = 2147483648;
      reason = "Kimchi's pi-mcp-adapter caps tool timers at 2147483647 ms; larger timeouts are omitted.";
      valid = 2147483647;
    };
    kiro = {
      accepted.timeout = 600000;
      invalid = 600001;
      reason = "Kiro caps per-server timeouts at 600000 ms; larger values are omitted.";
      valid = 600000;
    };
  };
  boundRows = backend: runtime: bound: let
    check = timeout: expected:
      checkDelivery backend runtime {ai.mcpServers.raw = raw // {inherit timeout;};} {
        raw = rawStdio runtime "probe" // expected;
      };
  in
    checkRows "${backend}/${runtime} stdio timeout bounds" {
      "${toString bound.invalid} ms is omitted with the bound warning" =
        check bound.invalid {} ["ai.mcpServers.raw.timeout is set but ${backend} does not deliver it to ${runtime} (reason: ${bound.reason})"];
      "${toString bound.valid} ms is delivered without a warning" = check bound.valid bound.accepted [];
    };
  domainRows = backend: eval: let
    # Force just the shared option's timeout merge, before a client renderer.
    read = timeout: (eval {ai.mcpServers.raw = raw // {inherit timeout;};}).config.ai.mcpServers.raw.timeout;
    rejects = invalid:
      rejectsChange read {
        inherit invalid;
        expected = 1;
        valid = 1;
      };
  in
    checkRows "${backend} shared timeout domain" {
      "fractional milliseconds are rejected" = rejects 1.5;
      "negative milliseconds are rejected" = rejects (-1);
      "null selects the client default" = read null == null;
      "zero milliseconds are rejected" = rejects 0;
    };
  render = mcpLib.renderServer pkgs;
in {
  checks =
    {
      module-mcp-timeout-direct = mkTest "mcp-timeout-direct" (checkRows "direct MCP timeout" {
        "HTTP keeps the supplied timeout" =
          render "remote" (http // {timeout = 1501;})
          == (http
            // {
              timeout = 1501;
              type = "http";
            });
        "constructor omits the default timeout" = !(packaged ? timeout);
        "constructor retains the supplied timeout" = entries.nixos-mcp.timeout == 1501;
        "package renderer omits the default timeout" = !(render "nixos-mcp" packaged ? timeout);
        "package renderer retains the supplied timeout" = (render "nixos-mcp" entries.nixos-mcp).timeout == 1501;
        "raw renderer retains the supplied timeout" = (render "raw" entries.raw).timeout == 1501;
      });
      module-mcp-timeout-domain = mkTest "mcp-timeout-domain" (
        checkRows "shared MCP timeout" (lib.mapAttrs domainRows backends)
      );
    }
    // lib.mapAttrs' (backend: _:
      lib.nameValuePair "module-mcp-timeout-${backend}" (
        mkTest "mcp-timeout-${backend}" (checkRows "${backend} MCP timeouts" {
          bounds = checkRows "${backend} stdio bounds" (lib.mapAttrs (boundRows backend) bounds);
          delivery = checkRows "${backend} delivery" (lib.mapAttrs (deliveryRows backend) nativeTimeouts);
        })
      ))
    backends;
}
