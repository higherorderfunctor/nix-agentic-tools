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
      bound = {
        accepted.timeout = 1000;
        invalid = 999;
        reason = "Claude ignores per-server timeouts below 1000 ms; the timeout is omitted.";
        valid = 1000;
      };
      shared.timeout = 1501;
    };
    codex = {
      httpMs = 1501;
      replacement.tool_timeout_sec = 2.501;
      shared.tool_timeout_sec = 1.501;
    };
    kimchi = {
      bound = {
        accepted.requestTimeoutMs = 2147483647;
        invalid = 2147483648;
        reason = "Kimchi's pi-mcp-adapter caps tool timers at 2147483647 ms; larger timeouts are omitted.";
        valid = 2147483647;
      };
      shared.requestTimeoutMs = 1501;
    };
    kiro = {
      bound = {
        accepted.timeout = 600000;
        invalid = 600001;
        reason = "Kiro caps per-server timeouts at 600000 ms; larger values are omitted.";
        valid = 600000;
      };
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
    httpMs = native.httpMs or native.bound.invalid;
    remote = http // {timeout = httpMs;};
  in
    checkRows "${backend}/${runtime} timeout delivery" (
      {
        "HTTP preserves milliseconds without stdio conversion or bounds" = check {ai.mcpServers = {inherit remote;};} {
          remote =
            {
              inherit (http) url;
              timeout = httpMs;
            }
            // lib.optionalAttrs (runtime != "codex") {type = "http";};
        } [];

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
      // lib.optionalAttrs (backend == "hm" && runtime == "codex") {
        # Native tool timeout wins in the shared Codex renderer; generic
        # timeout never changes startup.
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

        # Both backends and all runtimes use the same runtime-over-shared
        # merge; stdio renderers do not depend on entry ownership.
        "runtime timeout replaces the shared value" = check (withOverrides {
          raw = {
            command = "override";
            timeout = 2501;
          };
        }) (shared // {raw = rawStdio runtime "override" // native.replacement;}) [];
      }
    );
  boundRows = backend: runtime: bound: let
    check = timeout: expected:
      checkDelivery backend runtime {ai.mcpServers.raw = raw // {inherit timeout;};} {
        raw = rawStdio runtime "probe" // expected;
      };
  in
    checkRows "${backend}/${runtime} stdio timeout bounds" (
      {
        "${toString bound.invalid} ms is omitted with the bound warning instead of leaking into the client file" =
          check bound.invalid {} ["ai.mcpServers.raw.timeout is set but ${backend} does not deliver it to ${runtime} (reason: ${bound.reason})"];
      }
      # The threshold is shared; check the backend-specific warning on both.
      // lib.optionalAttrs (backend == "hm") {
        "${toString bound.valid} ms is accepted at the inclusive boundary without a warning" = check bound.valid bound.accepted [];
      }
    );
  domainRows = let
    # Force just the shared option's timeout merge, before a client renderer.
    # Both backends import the same declaration, so exercise it through HM.
    read = timeout: (evalHm {ai.mcpServers.raw = raw // {inherit timeout;};}).config.ai.mcpServers.raw.timeout;
    rejects = invalid:
      rejectsChange read {
        inherit invalid;
        expected = 1;
        valid = 1;
      };
  in
    checkRows "hm shared timeout domain" {
      "fractional milliseconds are rejected even when positive" = rejects 1.5;
      "negative milliseconds are rejected even when nonzero" = rejects (-1);
      "null remains valid when the shared entry explicitly selects the client default" = read null == null;
      "zero milliseconds are rejected even when unsigned" = rejects 0;
    };
  render = mcpLib.renderServer pkgs;
  # The standalone API bypasses the module merge, so missing options have no
  # schema defaults. Supply only the package that the named server needs.
  standalone = config:
    (mcpLib.mkStdioConfig (pkgs // {ai.mcpServers.nixos-mcp = pkgs.hello;}) {nixos-mcp = config;}).mcpServers.nixos-mcp;
in {
  checks =
    {
      module-mcp-timeout-direct = mkTest "mcp-timeout-direct" (checkRows "direct MCP timeout" {
        "a bare HTTP entry keeps its timeout without module defaults for headers" =
          render "remote" (http // {timeout = 1501;})
          == (http
            // {
              timeout = 1501;
              type = "http";
            });
        "constructor does not insert a null timeout into the typed record" = !(packageEntry {} ? timeout);
        "standalone config renders a package without adding or requiring a timeout" = standalone {} == packagedStdio "claude";
        "standalone config forwards the caller's timeout without module merging" =
          standalone {timeout = 1501;} == (packagedStdio "claude" // {timeout = 1501;});
      });
      module-mcp-timeout-domain = mkTest "mcp-timeout-domain" domainRows;
    }
    // lib.mapAttrs' (backend: _:
      lib.nameValuePair "module-mcp-timeout-${backend}" (
        mkTest "mcp-timeout-${backend}" (checkRows "${backend} MCP timeouts" {
          bounds = checkRows "${backend} stdio bounds" (lib.mapAttrs
            (runtime: native: boundRows backend runtime native.bound)
            (lib.filterAttrs (_: native: native ? bound) nativeTimeouts));
          # Claude has separate delivery paths; the other clients share their
          # translation. The bounds rows still force the Kimchi and Kiro
          # project files; Codex's project TOML is checked in its owner suite.
          delivery = checkRows "${backend} delivery" (lib.mapAttrs
            (deliveryRows backend)
            (lib.filterAttrs (runtime: _: backend == "hm" || runtime == "claude") nativeTimeouts));
        })
      ))
    backends;
}
