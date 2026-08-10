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
# devenv copy's `mcpServers`, `instructions`, `skills` and `skillsDir`
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
#     <backend> ? {
#       options ? {};          # backend-only option additions
#       defaults ? {};         # backend-only default overrides
#       config ? _: {};        # consumer callback:
#                              #   {cfg, config, merged*, topContext, topHooks,
#                              #    topSettings}
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
  # Collision-as-failure merges — shared ai.<pool> vs ai.<cli>.<pool>.
  # See lib/ai/ai-common.nix:mergeWithCollisionCheck. Assertions are
  # emitted through config.assertions below.
  mergeCheck = poolName: topPool: cliPool:
    aiCommon.mergeWithCollisionCheck {
      inherit poolName topPool cliPool;
      cliName = appRecord.name;
    };
  serversMerge = mergeCheck "mcpServers" config.ai.mcpServers cfg.mcpServers;
  skillsMerge = mergeCheck "skills" config.ai.skills cfg.skills;
  rulesMerge = mergeCheck "rules" config.ai.rules cfg.rules;
  lspMerge = mergeCheck "lspServers" config.ai.lspServers (cfg.lspServers or {});
  envMerge = mergeCheck "environmentVariables" config.ai.environmentVariables (cfg.environmentVariables or {});
  agentsMerge = mergeCheck "agents" config.ai.agents (cfg.agents or {});
  collisionAssertions =
    serversMerge.assertions
    ++ skillsMerge.assertions
    ++ rulesMerge.assertions
    ++ lspMerge.assertions
    ++ envMerge.assertions
    ++ agentsMerge.assertions;
  # ── Local credential-injecting proxy split ──────────────────────
  # A server with `proxy.enable` has its url + headers moved into a
  # systemd user daemon (lib/ai/mcpProxy.nix) and is handed to every
  # ecosystem as a credential-free loopback entry. This runs BEFORE the
  # per-app callback, so no factory — Kiro's credential preprocessor
  # included — ever sees the secret for a proxied server, and the
  # rendered entry passes `renderServer`'s non-Kiro credential guards
  # because there is no credential left in it.
  rawMergedServers = serversMerge.merged;
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

  proxyAssertions = [
    {
      assertion = proxiedWithoutUrl == [];
      message = "ai.${appRecord.name}.mcpServers: ${lib.concatStringsSep ", " proxiedWithoutUrl} set `proxy.enable` but no `url`. The proxy forwards to that url, so there is nothing to proxy to — set `url` (a plain string or a credential), or drop `proxy.enable`.";
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
        # The decrypted values live only here and in the process's own
        # memory: /proc/<pid>/environ is 0400, while /proc/<pid>/cmdline
        # is world-readable — which is why nothing is passed as argv.
        PrivateTmp = true;
      };
      Install.WantedBy = ["default.target"];
    })
  proxiedServers;

  # Opt-in, per app record. An app earns `ai.<name>.shell` only by
  # declaring `supportsShell = true`, which means it actually maps the
  # value onto a knob its runtime reads. Apps that do not (Copilot,
  # Kimchi — neither runtime's shell selection has been established)
  # get NO option at all, so setting one is an "option does not exist"
  # eval error rather than a value that evaluates cleanly and is then
  # dropped on the floor. The repo rule is that a surface without a
  # lossless native mapping is an explicit exclusion, not a silent
  # no-op.
  #
  # Reading it off the RECORD keeps it a build-time parameter, in the
  # same category as `backend` above: it forces neither `config` nor
  # the factory's `pkgs`, so it cannot reintroduce the `_module.args`
  # recursion documented against `proxyIsSupported` below.
  supportsShell = appRecord.supportsShell or false;

  # Override-wins, NOT collision-as-failure — see the contrast note on
  # `resolveOverride` in lib/ai/ai-common.nix. Left null when the app
  # opts out, so a callback that ignores it cannot accidentally emit a
  # root-level shell the runtime never reads.
  resolvedShell =
    if supportsShell
    then
      aiCommon.resolveOverride {
        topValue = config.ai.shell;
        cliValue = cfg.shell or null;
      }
    else null;

  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = skillsMerge.merged;
  mergedRules = rulesMerge.merged;
  mergedLspServers = lspMerge.merged;
  mergedEnvironmentVariables = envMerge.merged;
  mergedAgents = agentsMerge.merged;
  topContext = config.ai.context;
  topHooks = config.ai.hooks;
  topSettings = config.ai.settings;

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
    inherit cfg config mergedServers mergedInstructions mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables mergedAgents resolvedShell topContext topHooks topSettings;
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
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        });
        default = {};
        description = "${appRecord.name}-specific MCP servers (merged with top-level ai.mcpServers; collisions fail).";
      };
      instructions = lib.mkOption {
        type = lib.types.listOf aiCommon.instructionModule;
        default = [];
        description = "${appRecord.name}-specific instructions (appended to top-level ai.instructions; Kiro supports an explicit inclusion mode).";
      };
      rules = lib.mkOption {
        type = lib.types.attrsOf aiCommon.ruleModule;
        default = {};
        description = "${appRecord.name}-specific rules (merged with top-level ai.rules; collisions fail).";
      };
      rulesDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory of `.md` rule files. Each
          file becomes one entry in `ai.${appRecord.name}.rules` keyed by
          the basename minus `.md`. Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default keeps `.md`).
          Runs through the same collision-as-failure merge with
          `ai.rules` as explicit per-CLI entries; other derivations may
          still contribute to the same on-disk rules dir.
        '';
      };
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills (merged with top-level ai.skills; collisions fail).";
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
    # Declared ONLY for apps that map it onto a knob their runtime
    # actually reads — see `supportsShell` above.
    // lib.optionalAttrs supportsShell {
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
    # Collision-as-failure: always evaluate (no mkIf cfg.enable
    # guard) so misconfigurations surface even when the feature
    # is toggled off.
    {assertions = collisionAssertions ++ proxyAssertions;}
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
    # unconditionally (no mkIf cfg.enable) so the collision check
    # still has visibility even when the CLI is disabled — the
    # actual on-disk emission is still gated by `cfg.enable` inside
    # the per-CLI factory's customConfig.
    (lib.mkIf (cfg.rulesDir != null) {
      ai.${appRecord.name}.rules = lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.rulesFromDir cfg.rulesDir
      );
    })
    (lib.mkIf (cfg.skillsDir != null) {
      ai.${appRecord.name}.skills = lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.skillsFromDir cfg.skillsDir
      );
    })
    (lib.mkIf cfg.enable customConfig)
  ];
}
