# services.mcp-servers home-manager module.
#
# Reconstitutes the per-server typed options (enable, settings,
# credentials, service.port/host), mcpConfig output, tools registry,
# and systemd user services that were dropped during the factory
# refactor. Each server's definition is loaded from the per-package
# `packages/<name>/modules/mcp-server.nix` via lib/mcp.nix:loadServer.
#
# Picked up by collectFacet ["modules" "homeManager"] in flake.nix.
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
    "fetch-mcp"
    "git-intel-mcp"
    "git-mcp"
    "github-mcp"
    "gitlab-mcp"
    "kagi-mcp"
    "nixos-mcp"
    "openmemory-mcp"
    "sequential-thinking-mcp"
    "serena-mcp"
    "sympy-mcp"
  ];

  serverFiles =
    builtins.listToAttrs
    (map (name:
      nameValuePair name (mcpLib.loadServer name))
    serverNames);

  # ── Package resolution ─────────────────────────────────────────────
  # Most servers live at pkgs.ai.mcpServers.<name>. Servers from the
  # modelcontextprotocol mono-repo live under
  # pkgs.ai.mcpServers.modelContextProtocol.<name>.
  modelContextProtocolServers = [
    "fetch-mcp"
    "git-mcp"
    "sequential-thinking-mcp"
  ];

  resolvePackage = name:
    if builtins.elem name modelContextProtocolServers
    then pkgs.ai.mcpServers.modelContextProtocol.${name}
    else pkgs.ai.mcpServers.${name};

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
    # widening nine services at once.
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
        ++ optionals (httpCmd == "bridge") [pkgs.ai.mcpServers.mcp-proxy];
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
          $VERBOSE_ECHO "mcp-servers: credential for ${unit} rotated -- restarting"
          run ${pkgs.systemd}/bin/systemctl --user restart ${escapeShellArg unit} || true
        fi
        # The hash write goes through `tee`, NOT `printf > "$hash_file"`, and
        # that is load-bearing rather than stylistic: home-manager's `run`
        # wraps a COMMAND AND ITS ARGUMENTS, so a shell redirection attached
        # to it is performed by the CALLING shell and fires on a dry run
        # regardless. `run printf '%s' "$h" > "$hash_file"` would therefore
        # still truncate-and-write under DRY_RUN. Routing the write through a
        # command `run` can actually suppress is the only form that is inert.
        #
        # The ordering matters too, and is why the write is inside `run` at
        # all rather than merely after the restart: writing the hash during a
        # dry run makes the NEXT real activation see an unchanged hash and
        # skip a restart that was genuinely needed, so a "harmless" dry run
        # would silently destroy pending rotation work.
        printf '%s' "$new_hash" | run --quiet ${pkgs.coreutils}/bin/tee -- "$hash_file" || true
      fi
    fi
  '';

  # Every MUTATING command below is routed through home-manager's `run`
  # helper, which is a no-op-plus-echo when DRY_RUN is set. Reads are
  # deliberately NOT wrapped -- a dry run must still evaluate its conditions
  # in order to report accurately what a real run would do.
  #
  # `run` is the CURRENT mechanism for DRY-RUN ROUTING: the activation
  # script's own preamble marks DRY_RUN_CMD and DRY_RUN_NULL deprecated and
  # back-compat-only, so new mutating commands must not reach for those.
  #
  # THE SAME PREAMBLE ALSO DEPRECATES VERBOSE_ECHO, and the status message in
  # mkRotationCheck above STILL USES IT. That is INTENTIONALLY RETAINED, not
  # an oversight: swapping it for the current `verboseEcho` helper is a
  # behavior change that nothing available at build time can verify, since
  # the difference only shows up during a real activation. It is tracked
  # separately rather than folded into a change whose live acceptance checks
  # already have to be run by hand. Scope this paragraph's rule to the
  # DRY-RUN helpers; it is deliberately NOT a claim that the snippet is free
  # of every deprecated variable.
  rotationRestartScript = ''
    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/mcp-cred-hashes"
    run ${pkgs.coreutils}/bin/mkdir -p "$state_dir" || true
    run ${pkgs.coreutils}/bin/chmod 700 "$state_dir" || true
    ${concatStringsSep "\n" (mapAttrsToList mkRotationCheck credentialedServiceFiles)}
  '';
in {
  # ── Options ────────────────────────────────────────────────────────
  options.services.mcp-servers = {
    servers = mapAttrs (name: serverDef:
      mkOption {
        type = types.submodule (mkServiceModule {
          inherit name serverDef resolvePackage;
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

    systemd.user.services = mkIf pkgs.stdenv.isLinux (mapAttrs' (name: srv: let
      serverDef = serverFiles.${name};
      srvEnv = effectiveEnvFor name srv "http";
      # Optional per-server ExecStartPre (e.g. openmemory pre-creating its
      # dimensioned pgvector table before the daemon inits — see the server
      # module's settingsToPreStart). Absent → no ExecStartPre.
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
    home.activation = mkIf (pkgs.stdenv.isLinux && credentialedServiceFiles != {}) {
      mcpRestartOnSecretRotation =
        lib.hm.dag.entryAfter ["linkGeneration" "sops-nix"] rotationRestartScript;
    };
  };
}
