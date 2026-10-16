# services.mcp-servers home-manager module.
#
# Reconstitutes the per-server typed options (enable, settings,
# credentials, service.port/host), mcpConfig output, tools registry,
# and systemd user services that were dropped during the factory
# refactor. Each server's definition is loaded from the per-package
# `packages/<name>/modules/mcp-server.nix` via lib/mcp.nix:loadServer.
#
# Picked up by native Home Manager module discovery in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Shared shell-hardening settings — see config/shell-strict.nix.
  shellStrict = import ../../../../config/shell-strict.nix;
  inherit
    (lib)
    concatLists
    concatStringsSep
    escapeShellArg
    filterAttrs
    getExe
    map
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    optionalAttrs
    optionalString
    optionals
    types
    ;

  mcpLib = import ../../../../lib/mcp.nix {inherit lib;};
  serviceSchema = import ../../../../lib/ai/mcpServer/serviceSchema.nix {inherit lib;};
  mkServiceModule = import ../../../../lib/ai/mcpServer/mkServiceModule.nix {inherit lib;};

  cfg = config.services.mcp-servers;

  # ── Server registry ────────────────────────────────────────────────
  # Maps server names to their definitions loaded from per-package
  # modules/mcp-server.nix files. The name is the package directory
  # name under packages/.
  serverNames = [
    "context7-mcp"
    "effect-mcp"
    "git-intel-mcp"
    "github-mcp"
    "gitlab-mcp"
    "kagi-mcp"
    "nixos-mcp"
  ];

  serverFiles =
    builtins.listToAttrs
    (map (name:
      nameValuePair name (mcpLib.loadServer name))
    serverNames);

  # ── Package resolution ─────────────────────────────────────────────
  # Defaults come from this flake's package tree (ai.internal.packages),
  # where every server lives at mcpServers.<name>.
  packagePath = name: "mcpServers.${name}";
  resolvePackage = name: lib.getAttrFromPath (lib.splitString "." (packagePath name)) config.ai.internal.packages;
  packageText = name: import ../../../../lib/ai/nat-package-text.nix {inherit lib;} (packagePath name);

  # ── Credentials helpers ──────────────────────────────────────────────
  credentialVarsFor = name: serverFiles.${name}.meta.credentialVars or {};

  # ── Derived sets ───────────────────────────────────────────────────
  enabledServers = filterAttrs (_: srv: srv.enable) cfg.servers;

  # Servers eligible for HTTP mcpConfig entries -- must have HTTP mode
  httpServers =
    filterAttrs
    (name: _: serviceSchema.hasHttpMode serverFiles.${name})
    enabledServers;

  # Servers eligible for systemd services -- must have local package + HTTP mode
  serviceServers =
    filterAttrs
    (name: _: serviceSchema.hasServiceCapability serverFiles.${name})
    enabledServers;

  # ── Delegate entry building to lib ─────────────────────────────────
  mkHttpEntryForServer = name: srv: let
    serverDef = serverFiles.${name};
    isBridge = (serverDef.meta.modes.http or "") == "bridge";
    baseEntry = mcpLib.mkHttpEntry ({
        inherit name;
        inherit (srv) settings;
      }
      // optionalAttrs (serviceSchema.hasServiceCapability serverDef) {
        inherit (srv.service) port host;
      });
  in
    # Bridge servers use mcp-proxy which serves on /mcp
    if isBridge && !(srv.settings ? path)
    then baseEntry // {url = baseEntry.url + "/mcp";}
    else baseEntry;

  # ── Build ExecStart for systemd services ───────────────────────────
  mkExecStart = name: srv: let
    serverDef = serverFiles.${name};
    inherit (serverDef.meta) modes;
    httpCmd = modes.http;
    stdioCmdForBridge = modes.stdio;

    effectiveMode =
      if httpCmd == "bridge"
      then "stdio"
      else "http";
    srvArgs = effectiveArgsFor name srv effectiveMode;
    argsStr = concatStringsSep " " (map escapeShellArg srvArgs);
    credVars = credentialVarsFor name;
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    hasCreds = mcpLib.hasCredentials credVars evaluatedSettings;

    credSnippet =
      if hasCreds
      then mcpLib.mkCredentialsSnippet pkgs credVars evaluatedSettings
      else "";

    # `--host` is passed explicitly rather than left to mcp-proxy's own
    # default. That default IS 127.0.0.1 today, so bridge servers were
    # already loopback-only — but by mcp-proxy's happenstance, not by
    # anything this repo states, and `service.host` was silently discarded
    # for every bridge server. Naming it makes the declared option
    # load-bearing and stops an upstream default change from quietly
    # widening every bridge service at once.
    #
    # Interpolated literally instead of via an env var: the bridge runs with
    # `--pass-environment`, so anything exported to the unit also lands in
    # the spawned stdio child's environment, and the bind address is the
    # proxy's business alone.
    rawCmd =
      if httpCmd == "bridge"
      then "mcp-proxy --pass-environment --host ${escapeShellArg srv.service.host} --port \"$MCP_PORT\" -- ${stdioCmdForBridge}"
      else httpCmd;

    wrapper = pkgs.writeShellApplication {
      name = "mcp-" + name + "-start";
      extraShellCheckFlags = shellStrict.shellcheckFlags;
      inherit (shellStrict) bashOptions;
      runtimeInputs =
        [srv.package]
        ++ optionals (httpCmd == "bridge") [config.ai.internal.packages.mcpServers.mcp-proxy];
      text = ''
        ${shellStrict.shoptHeader}
        ${credSnippet}
        exec ${rawCmd}${optionalString (argsStr != "") " ${argsStr}"}
      '';
    };
  in
    getExe wrapper;

  # ── Effective env/args for systemd services ────────────────────────
  effectiveEnvFor = name: srv: mode: let
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    cfgShim = mcpLib.mkCfgShim {
      inherit evaluatedSettings;
      inherit (srv.service) port host;
    };
  in
    mcpLib.effectiveEnv name cfgShim mode srv.env;

  effectiveArgsFor = name: srv: mode: let
    evaluatedSettings = mcpLib.evalSettings name srv.settings;
    cfgShim = mcpLib.mkCfgShim {
      inherit evaluatedSettings;
      inherit (srv.service) port host;
    };
  in
    mcpLib.effectiveArgs name cfgShim mode srv.args;

  # ── Restart long-lived services on credential rotation ─────────────
  # A service unit reads its credential file once, at ExecStart. A
  # rotated secret keeps the same *path*, so the generated unit is
  # byte-identical -- neither home-manager nor systemd restarts it, and
  # the process keeps serving with the stale token. This activation step
  # fingerprints each service's credential file(s) and restarts the unit
  # only when the content actually changed. Secret-manager agnostic: it
  # needs a stable path, not sops/agenix internals. Ordered after the
  # `sops-nix` activation entry so we hash the freshly-rendered secret;
  # the dependency is silently ignored when sops-nix is not in use.
  credentialedServiceFiles =
    filterAttrs (_: paths: paths != [])
    (mapAttrs (name: srv:
      mcpLib.credentialFilePaths
      (credentialVarsFor name)
      (mcpLib.evalSettings name srv.settings))
    serviceServers);

  mkRotationCheck = name: paths: let
    unit = "mcp-" + name + ".service";
    readableGuard = concatStringsSep " && " (map (p: "[ -r ${escapeShellArg p} ]") paths);
    pathArgs = concatStringsSep " " (map escapeShellArg paths);
  in ''
    hash_file="$state_dir/${name}"
    if ${readableGuard}; then
      if new_hash="$(${pkgs.coreutils}/bin/cat -- ${pathArgs} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1)"; then
        old_hash=""
        if [ -r "$hash_file" ]; then
          old_hash="$(${pkgs.coreutils}/bin/cat -- "$hash_file")"
        fi
        if [ -n "$old_hash" ] && [ "$old_hash" != "$new_hash" ] \
          && ${pkgs.systemd}/bin/systemctl --user is-active --quiet ${escapeShellArg unit}; then
          printf '%s\n' "mcp-servers: credential for ${unit} rotated -- restarting"
          ${pkgs.systemd}/bin/systemctl --user restart ${escapeShellArg unit} || true
        fi
        printf '%s' "$new_hash" > "$hash_file" || true
      fi
    fi
  '';

  # Layer 3 wraps the whole command in Home Manager's dry-run helper. Its
  # child shell needs no activation-shell functions for reads or mutations.
  rotationRestartScript = ''
    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/mcp-cred-hashes"
    ${pkgs.coreutils}/bin/mkdir -p "$state_dir" || true
    ${pkgs.coreutils}/bin/chmod 700 "$state_dir" || true
    ${concatStringsSep "\n" (mapAttrsToList mkRotationCheck credentialedServiceFiles)}
  '';
in {
  imports = [
    (import ../../../ai-module/lib/runtime.nix {
      enabled = enabledServers != {};
      name = "mcp-services";
    })
  ];

  # ── Options ────────────────────────────────────────────────────────
  options.services.mcp-servers = {
    servers = mapAttrs (name: serverDef:
      mkOption {
        type = types.submodule (mkServiceModule {
          inherit name packageText serverDef resolvePackage;
        });
        default = {};
        description = "Configuration for the ${name} MCP server.";
      })
    serverFiles;

    mcpConfig = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      description = ''
        Generated mcp.json-compatible configuration from enabled servers.
        All HTTP servers produce plain { type = "http"; url = "..."; } entries.
        Reference as `config.services.mcp-servers.mcpConfig` from other modules.
      '';
    };

    tools = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      description = ''
        Tool names exposed by each enabled server (from upstream metadata).
        Use this to build client-specific auto-approval configs by filtering
        and formatting with standard Nix functions.
      '';
    };
  };

  # ── Implementation ─────────────────────────────────────────────────
  config = {
    services.mcp-servers = {
      mcpConfig.mcpServers = mapAttrs mkHttpEntryForServer httpServers;
      tools = mapAttrs (name: _: serverFiles.${name}.meta.tools or []) enabledServers;
    };

    assertions = let
      credAssertions = concatLists (mapAttrsToList (name: srv: let
        serverDef = serverFiles.${name};
        credVars = serverDef.meta.credentialVars or {};
        evaluatedSettings = mcpLib.evalSettings name srv.settings;
      in
        concatLists (mapAttrsToList (optName: spec:
          lib.optional spec.required {
            assertion = evaluatedSettings.${optName} != null;
            message = "services.mcp-servers.servers.${name}.settings.${optName}: credentials are required (set file or helper)";
          })
        credVars))
      enabledServers);
    in
      credAssertions;

    systemd.user.services = mkIf pkgs.stdenv.hostPlatform.isLinux (mapAttrs' (name: srv: let
      serverDef = serverFiles.${name};
      srvEnv = effectiveEnvFor name srv "http";
      # Optional per-server ExecStartPre, contributed by a server module's
      # `settingsToPreStart`, for setup that must happen before the daemon
      # inits. NO SERVER DECLARES ONE TODAY: openmemory-mcp was the only
      # producer and was removed 2026-09-01. The seam is kept because it is
      # a generic schema hook rather than openmemory-specific code, and
      # `optionalAttrs (preStart != [])` below already makes the absent
      # case free. Absent → no ExecStartPre.
      preStart =
        if serverDef ? settingsToPreStart
        then
          serverDef.settingsToPreStart pkgs (mcpLib.mkCfgShim {
            evaluatedSettings = mcpLib.evalSettings name srv.settings;
            inherit (srv.service) port host;
          }) "http"
        else [];
    in
      nameValuePair ("mcp-" + name) {
        Unit = {
          Description = name + " MCP server";
          After = ["network.target"];
        };
        Service =
          {
            Type = "simple";
            ExecStart = mkExecStart name srv;
            Restart = "on-failure";
            RestartSec = 5;
            Environment =
              [("MCP_PORT=" + toString srv.service.port)]
              ++ mapAttrsToList (k: v: k + "=" + escapeShellArg v) srvEnv;
          }
          // optionalAttrs (preStart != []) {ExecStartPre = preStart;};
        Install = {
          WantedBy = ["default.target"];
        };
      })
    serviceServers);

    # Restart credentialed services when their secret file content
    # changes (token rotation). See mkRotationCheck above. Gated on
    # Linux (systemd user services) + at least one file-credentialed
    # service, so it is inert for stdio-only or credential-free setups.
    ai.mcp-services.activation2.mcp-restart-on-secret-rotation = {
      after = ["files" "secrets"];
      enable = pkgs.stdenv.hostPlatform.isLinux && credentialedServiceFiles != {};
      command = rotationRestartScript;
    };
  };
}
