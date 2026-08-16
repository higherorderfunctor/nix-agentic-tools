# Shared backend transformer body.
#
# `hmTransform.nix` and `devenvTransform.nix` were ~135 near-identical
# lines each. Every merge, every option declaration and the whole
# `config` block were duplicated verbatim; the ONLY functional
# difference was which key of the app record the backend-specific
# spec is read from (`hm` vs `devenv`). That is this file's `backend`
# argument, and nothing else differs.
#
# Keeping them as two copies meant every change to the shared option
# surface had to be made twice, and the two had already drifted — the
# devenv copy's `mcpServers`, `rules`, `skills` and `skillsDir`
# descriptions had lost the merge semantics the HM copy documented,
# even though both run the SAME merge code. Unifying on the fuller
# text makes the devenv option docs correct rather than terse.
#
# Input record shape (from mkAiApp):
#   {
#     name;
#     transformers;
#     defaults ? {package};
#     options ? {};            # shared across backends
#     supportedPools ? [];      # normalized ai.* pools this runtime consumes
#     contextDescription ? null;
#     rulesDescription ? null;
#     <backend> ? {
#       options ? {};          # backend-only option additions
#       defaults ? {};         # backend-only default overrides
#       config ? _: {};        # consumer callback:
#                              #   {cfg, config, merged*, mergedContext, topHooks,
#                              #    resolvedSettings}
#                              #   → module attrs
#     };
#     <other-backend> ? { ... };   # ignored here
#   }
#
# Returns: a module function `{config, ...}: { options; config; }`
# that can be imported into `lib.evalModules` alongside
# `lib/ai/sharedOptions.nix`.
{
  lib,
  # Which key of the app record carries this backend's spec.
  backend,
}: appRecord: {config, ...}: let
  aiCommon = import ../ai-common.nix {inherit lib;};
  dirHelpers = import ../dir-helpers.nix {inherit lib;};
  # `pkgs` comes off the RECORD, never from the module arguments. Naming
  # it in this function's formals makes the module system resolve it via
  # `_module.args`, which requires `config` and deadlocks against any
  # factory whose options use `pkgs.formats.json` as a freeform type —
  # see the note on `pkgs` in mkAiApp.nix.
  mcpProxy = import ../mcpProxy.nix {
    inherit lib;
    inherit (appRecord) pkgs;
  };
  cfg = config.ai.${appRecord.name};
  supportedPools = appRecord.supportedPools or [];
  supportsPool = poolName: builtins.elem poolName supportedPools;
  # Per-runtime entries replace root entries atomically. Null is a tombstone
  # filtered after precedence, so it suppresses a root entry at the same key.
  mergePool = poolName: topPool: cliPool:
    if supportsPool poolName
    then aiCommon.mergePool {inherit topPool cliPool;}
    else {};
  mergedAgents = mergePool "agents" config.ai.agents (cfg.agents or {});
  mergedEnvironmentVariables = mergePool "environmentVariables" config.ai.environmentVariables (cfg.environmentVariables or {});
  mergedLspServers = mergePool "lspServers" config.ai.lspServers (cfg.lspServers or {});
  mergedRules = mergePool "rules" config.ai.rules cfg.rules;
  rawMergedServers = mergePool "mcpServers" config.ai.mcpServers cfg.mcpServers;
  mergedSkills = mergePool "skills" config.ai.skills cfg.skills;
  # ── Local credential-injecting proxy split ──────────────────────
  # A server with `proxy.enable` has its url + headers moved into a
  # systemd user daemon (lib/ai/mcpProxy.nix) and is handed to every
  # ecosystem as a credential-free loopback entry. This runs BEFORE the
  # per-app callback, so no factory — Kiro's credential preprocessor
  # included — ever sees the secret for a proxied server, and the
  # rendered entry passes `renderServer`'s non-Kiro credential guards
  # because there is no credential left in it.
  proxiedServers = mcpProxy.proxiedServers rawMergedServers;
  mergedServers =
    rawMergedServers
    // lib.mapAttrs mcpProxy.clientEntry proxiedServers;

  # SCOPE — Home Manager only, and in practice Linux only because the
  # daemon is a systemd user service. Neither devenv nor Darwin is a
  # WONTFIX; see the `proxy` option in mcpServer/commonSchema.nix.
  #
  # Gated on `backend` ALONE, deliberately. `backend` is a build-time
  # parameter, so testing it forces nothing. Adding
  # `pkgs.stdenv.hostPlatform.isLinux` here would force the `pkgs` module
  # argument while the `config` attrset is being CONSTRUCTED, and `pkgs`
  # resolves through `_module.args`, which requires `config` — an
  # infinite recursion that surfaces far away, as
  # "while evaluating the option `_module.freeformType'" in a factory
  # that uses `pkgs.formats.json` for a freeform type. Every other `pkgs`
  # use below sits inside an attribute VALUE and stays lazy.
  #
  # The Darwin gate is therefore documentation plus the devenv assertion,
  # not a platform conditional. home-manager's own systemd.user options
  # are already inert off Linux.
  # `backend` ONLY. Testing `appRecord.pkgs != null` here looks harmless
  # and is not: `appRecord.pkgs` is the factory's `pkgs` argument, so
  # forcing it inside the `optionalAttrs` CONDITION forces that argument
  # while `config` is being constructed. Under a harness that does not
  # externally provide `pkgs` (checks/options-doc.nix), it resolves
  # through `_module.args`, which requires `config` — the same infinite
  # recursion, reached by a different route.
  #
  # A null `pkgs` is caught by the lazy assertion below instead, and
  # `proxyUnits` is `{}` when nothing is proxied, so nothing forces it.
  proxyIsSupported = backend == "hm";

  # A proxied server with no `url` has nothing to forward to. The start
  # script would export no url variable, then dereference it under
  # `set -u` and die at SERVICE START with a bare unbound-variable error
  # naming a generated variable — far from the option that is actually
  # wrong. Reject it at eval, where the message can name the server.
  proxiedWithoutUrl =
    builtins.attrNames
    (lib.filterAttrs (_: srv: (srv.url or null) == null) proxiedServers);

  # A proxied server's TOP-LEVEL `headers` are the CLIENT's, and the
  # client entry is an unauthenticated loopback url — so a credential
  # there would be written into the client's config, which is the exact
  # thing the proxy exists to prevent. Injected credentials belong in
  # `proxy.headers`.
  #
  # This is also the migration message. Before 2026-08-13 top-level
  # credential headers were ABSORBED into the daemon when `proxy.enable`
  # was set; anything written against that shape must move. Failing loudly
  # is deliberate — silently absorbing them is what made one key mean two
  # things, and silently passing them through would leak.
  proxiedWithCredentialHeaders =
    builtins.attrNames
    (lib.filterAttrs
      (_: srv:
        builtins.any
        (v: builtins.isAttrs v && (v ? file || v ? helper))
        (builtins.attrValues (srv.headers or {})))
      proxiedServers);

  proxyAssertions = [
    {
      assertion = proxiedWithoutUrl == [];
      message = "ai.${appRecord.name}.mcpServers: ${lib.concatStringsSep ", " proxiedWithoutUrl} set `proxy.enable` but no `url`. The proxy forwards to that url, so there is nothing to proxy to — set `url` (a plain string or a credential), or drop `proxy.enable`.";
    }
    {
      assertion = proxiedWithCredentialHeaders == [];
      message = "ai.${appRecord.name}.mcpServers: ${lib.concatStringsSep ", " proxiedWithCredentialHeaders} set `proxy.enable` and put a CREDENTIAL in the server's top-level `headers`. On a proxied server those are the CLIENT's headers and are written into its config, which would hand it the credential the proxy exists to withhold. Move them to `proxy.headers`, where the daemon injects them and no client ever sees the value. (Top-level `headers` used to be absorbed into the daemon automatically; that behavior was removed so the key means one thing.)";
    }
    {
      assertion = appRecord.pkgs != null || proxiedServers == {};
      message = "ai.${appRecord.name}.mcpServers: ${lib.concatStringsSep ", " (builtins.attrNames proxiedServers)} set `proxy.enable`, but the ${appRecord.name} app record carries no `pkgs`, so the proxy daemon cannot be built. Pass `inherit pkgs;` to `mkAiApp` in that factory.";
    }
    {
      assertion = backend != "devenv" || proxiedServers == {};
      message = "ai.${appRecord.name}.mcpServers: ${lib.concatStringsSep ", " (builtins.attrNames proxiedServers)} set `proxy.enable`, which the devenv backend does not implement. The proxy is a systemd user service and devenv has no equivalent wired yet — deliberately out of scope, NOT a decision against it. Declare these servers in Home Manager, or drop `proxy.enable` and accept client-side credentials.";
    }
  ];

  # One unit per proxied server, keyed by SERVER name rather than by app,
  # so a server shared across two enabled ecosystems yields one daemon.
  # Two apps seeing the same top-level server produce byte-identical
  # definitions, which the module system merges; they differ only if the
  # server itself differs, and that is a real conflict worth failing on.
  proxyUnits = lib.mapAttrs' (name: srv: let
    spec = mcpProxy.specFor name srv;
  in
    lib.nameValuePair "mcp-proxy-${name}" {
      Unit = {
        Description = "Credential-injecting MCP proxy for ${name}";
        After = ["network.target"];
      };
      Service = {
        ExecStart = "${mcpProxy.startScriptFor spec}";
        Restart = "on-failure";
        RestartSec = 5;
        # Per-server attribution in the journal. Without this the visible
        # identifier is the ExecStart store basename — the server name
        # behind a 32-char hash that CHANGES ON EVERY REBUILD. That is
        # load-bearing rather than cosmetic: the logs carry no request
        # headers at all (see mcpProxy.nix), so the unit is the only thing
        # that says which proxy a line came from.
        SyslogIdentifier = "mcp-proxy-${name}";
        # The decrypted values live only here and in the process's own
        # memory: /proc/<pid>/environ is 0400, while /proc/<pid>/cmdline
        # is world-readable — which is why nothing is passed as argv.
        PrivateTmp = true;
      };
      Install.WantedBy = ["default.target"];
    })
  proxiedServers;

  # One capability source per app record. A normalized pool is declared,
  # merged and fanned out only when the runtime consumes it.
  # Unsupported per-runtime writes therefore get an "option does not exist"
  # eval error, while unsupported root fanout deliberately degrades to the
  # pool's neutral value.
  #
  # Reading it off the RECORD keeps it a build-time parameter, in the
  # same category as `backend` above: it forces neither `config` nor
  # the factory's `pkgs`, so it cannot reintroduce the `_module.args`
  # recursion documented against `proxyIsSupported` below.
  # Null inherits for this scalar; keyed-pool nulls are tombstones instead.
  # Left null when the app
  # opts out, so a callback that ignores it cannot accidentally emit a
  # root-level shell the runtime never reads.
  resolvedShell =
    if supportsPool "shell"
    then
      aiCommon.resolveOverride {
        topValue = config.ai.shell;
        cliValue = cfg.shell or null;
      }
    else null;

  # Normalized settings narrow the root one field at a time. This is a
  # translation input only: factories render supported fields into their
  # nativeSettings option at mkDefault priority, and native option merging
  # arbitrates against consumer-authored values.
  resolvedSettings =
    if supportsPool "settings"
    then {
      reasoningEffort = aiCommon.resolveOverride {
        topValue = config.ai.settings.reasoningEffort;
        cliValue = cfg.settings.reasoningEffort;
      };
    }
    else {};

  # Module-contributed process env, delivered on the internal channel rather
  # than through `ai.<cli>.environmentVariables` — see the note on
  # `_sandboxSafeSshCommand` in sharedOptions.nix for why internal contributions
  # do not belong in the consumer-facing override pool.
  #
  # Callers merge this UNDER `mergedEnvironmentVariables`, so an explicit
  # consumer entry for the same key wins. That ordering is the contract; do
  # not flip it at a call site.
  sandboxSshCommand = config.ai._sandboxSafeSshCommand or null;
  moduleEnvironmentVariables = lib.optionalAttrs (sandboxSshCommand != null) {
    GIT_SSH_COMMAND = sandboxSshCommand;
  };

  mergedContext =
    if supportsPool "context"
    then aiCommon.composeContent [config.ai.context cfg.context]
    else null;
  topHooks =
    if supportsPool "hooks"
    then config.ai.hooks
    else {};

  backendSpec = appRecord.${backend} or {};
  backendOptions = backendSpec.options or {};
  backendDefaults = backendSpec.defaults or {};
  backendConfigFn = backendSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = backendDefaults.package or defaults.package or null;

  # `config` rides along so callbacks can observe sibling backend
  # options — e.g. the devenv materializer's conditional `devenv:files`
  # task edge needs `config.files != {}`.
  customConfig = backendConfigFn {
    inherit cfg config mergedServers mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables moduleEnvironmentVariables mergedAgents mergedContext resolvedSettings resolvedShell topHooks;
  };
in {
  options.ai.${appRecord.name} =
    {
      enable = lib.mkEnableOption appRecord.name;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "The ${appRecord.name} package.";
      };
      internal = lib.mkOption {
        type = lib.types.submodule {
          options._integration_writable_roots = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            internal = true;
            visible = false;
            description = "Writable roots contributed by integrations for runtimes that support them.";
          };
        };
        default = {};
        internal = true;
        visible = false;
        description = "Internal module-to-runtime integration channel.";
      };
    }
    // lib.optionalAttrs (supportsPool "mcpServers") {
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        }));
        default = {};
        description = "${appRecord.name}-specific MCP servers. Entries replace top-level ai.mcpServers at the same key; null suppresses an inherited server.";
      };
    }
    // lib.optionalAttrs (supportsPool "settings") {
      settings = lib.mkOption {
        type = aiCommon.normalizedSettingsType;
        default = {};
        description = ''
          Normalized ${appRecord.name} settings. A non-null field overrides
          the matching `ai.settings` default for this runtime; null inherits
          the root value. Supported fields translate into native keys at
          `mkDefault` priority. Set the corresponding key under
          `ai.${appRecord.name}.nativeSettings`, including an explicit null,
          to arbitrate against the derived value.
        '';
      };
    }
    // lib.optionalAttrs (supportsPool "context") {
      context = lib.mkOption {
        type = aiCommon.runtimeContextModule (appRecord.contextFilename or (throw "${appRecord.name}: supportedPools includes context but the app record has no contextFilename"));
        default = {};
        apply = aiCommon.validateOptionalContent;
        description =
          appRecord.contextDescription or ''
            ${appRecord.name}-specific context appended after `ai.context` in
            the runtime's single always-on `${appRecord.contextFilename}` file.
            Set exactly one of `text` or `source`; `filename` controls the native
            artifact name.
          '';
      };
    }
    // lib.optionalAttrs (supportsPool "rules") {
      rules = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr (appRecord.ruleModule or aiCommon.ruleModule));
        default = {};
        apply = aiCommon.validateRules;
        description = appRecord.rulesDescription or "${appRecord.name}-specific rules. Entries replace top-level ai.rules at the same key; null suppresses an inherited rule.";
      };
      rulesDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory of `.md` rule files. Each
          file becomes one entry in `ai.${appRecord.name}.rules` keyed by
          the basename minus `.md`. Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default keeps `.md`).
          Entries use the same per-runtime replacement semantics as explicit
          values; other derivations may still contribute to the same on-disk
          rules directory.
        '';
      };
    }
    // lib.optionalAttrs (supportsPool "skills") {
      skills = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
        default = {};
        description = "${appRecord.name}-specific skills. Entries replace top-level ai.skills at the same key; null suppresses an inherited skill.";
      };
      skillsDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory-of-directories; each
          immediate subdirectory becomes one entry in
          `ai.${appRecord.name}.skills` keyed by the subdir name.
          Accepts a path literal or `{ path, filter? }`.
        '';
      };
    }
    // lib.optionalAttrs (supportsPool "shell") {
      shell = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression "pkgs.bash";
        description = ''
          Shell ${appRecord.name} uses to execute the commands it runs.
          `null` (the default) inherits `ai.shell`; a non-null value here
          wins over it. With both null the shell is left untouched.
        '';
      };
    }
    // (appRecord.options or {})
    // backendOptions;

  config = lib.mkMerge [
    {_module.args.aiTransformers = appRecord.transformers;}
    {assertions = proxyAssertions;}
    # The proxy daemon is emitted OUTSIDE `mkIf cfg.enable`, unlike the
    # on-disk config. A client entry pointing at a dead loopback port is
    # a confusing failure, so the daemon's lifetime follows the SERVER
    # declaration rather than any one ecosystem being turned on.
    #
    # `optionalAttrs`, NOT `lib.mkIf`. This body is shared with the devenv
    # backend, which has no `systemd` option at all, and `mkIf false` still
    # places the attribute path in the definition tree — the module system
    # then rejects it with "The option `systemd' does not exist" even though
    # the condition is false. Only dropping the key outright works, and it
    # is safe because `backend` is a build-time parameter, not config.
    #
    # The condition must be answerable WITHOUT touching `config` or the
    # factory's `pkgs`. Both were tried and both are infinite recursions:
    # `appRecord.pkgs != null` forces a module argument that resolves
    # through `_module.args`, and `proxiedServers != {}` forces
    # `config.ai.mcpServers` while `config` is being constructed. `backend`
    # is a build-time parameter and forces nothing.
    #
    # Consequence: for the HM backend this key is ALWAYS defined, as `{}`
    # when nothing is proxied. Any harness evaluating this transform must
    # therefore declare a `systemd.user.services` option — `hmStubs` in
    # checks/factory-eval.nix and checks/module-eval.nix do.
    (lib.optionalAttrs proxyIsSupported {
      systemd.user.services = proxyUnits;
    })
    # L2b → L3 fanout for per-CLI Dir options. Expansion happens
    # unconditionally (no mkIf cfg.enable) so the normalized option value is
    # complete even when the CLI is disabled. Actual on-disk emission remains
    # gated by `cfg.enable` inside the per-CLI factory's customConfig.
    (lib.optionalAttrs (supportsPool "rules") (lib.mkIf (cfg.rulesDir != null) {
      ai.${appRecord.name}.rules = lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.rulesFromDir cfg.rulesDir
      );
    }))
    (lib.optionalAttrs (supportsPool "skills") (lib.mkIf (cfg.skillsDir != null) {
      ai.${appRecord.name}.skills = lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.skillsFromDir cfg.skillsDir
      );
    }))
    (lib.mkIf cfg.enable customConfig)
  ];
}
