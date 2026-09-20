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
#       migrationConfig ? _: {}; # bounded cleanup emitted outside enable gate
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
}: appRecord: {
  config,
  options,
  ...
}: let
  adapters = import ../adapters {
    inherit lib;
    inherit (appRecord) pkgs;
  };
  aiCommon = import ../ai-common.nix {inherit lib;};
  deliveryMethod = import ../deliveryMethod.nix {inherit lib;};
  deliveryOptions = import ../delivery-options.nix {inherit lib;};
  dirHelpers = import ../dir-helpers.nix {inherit lib;};
  runtimeFiles = import ../runtime-files.nix {inherit lib;};
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
  deliveryWarnings = import ../delivery-warnings.nix {inherit lib;} {
    inherit appRecord backend config options;
  };
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
  # Proxy ownership is resolved at the declaration scope BEFORE fanout.
  # Top-level declarations contribute only their lowered credential-free
  # client entries here; sharedOptions.nix emits their one managed unit.
  # Runtime declarations lower independently and own their managed units
  # directly. Null tombstones survive lowering and are filtered by mergePool.
  topServers = mcpProxy.lowerClientEntries config.ai.mcpServers;
  runtimeServers = mcpProxy.lowerClientEntries cfg.mcpServers;
  mergedServers = mergePool "mcpServers" topServers runtimeServers;
  mergedSkills = mergePool "skills" config.ai.skills cfg.skills;

  # One capability source per app record. A normalized pool is declared,
  # merged and fanned out only when the runtime consumes it.
  # Unsupported per-runtime writes therefore get an "option does not exist"
  # eval error, while unsupported root fanout deliberately degrades to the
  # pool's neutral value, with a warning when the root request is non-empty.
  #
  # Reading it off the RECORD keeps it a build-time parameter, in the
  # same category as `backend` above: it forces neither `config` nor
  # the factory's `pkgs`, so it cannot introduce an `_module.args`
  # recursion while this module constructs `config`.
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

  contextValues = [config.ai.context cfg.context];
  # Presence must stay structural. `composeContent` reads source-backed bytes
  # when two values compose, so using `mergedContext != null` as a generator
  # gate would force a discarded default before B7 replacement or tombstone
  # arbitration.
  hasMergedContext =
    if supportsPool "context"
    then
      lib.any (value:
        aiCommon.hasContent value
        && ((value.text or null) == null || value.text != ""))
      contextValues
    else false;
  mergedContext =
    if supportsPool "context"
    then aiCommon.composeContent contextValues
    else null;
  topHooks =
    if supportsPool "hooks"
    then config.ai.hooks
    else {};

  backendSpec = appRecord.${backend} or {};
  backendOptions = backendSpec.options or {};
  backendDefaults = backendSpec.defaults or {};
  backendConfigFn = backendSpec.config or (_: {});
  migrationConfigFn = backendSpec.migrationConfig or (_: {});

  defaults = appRecord.defaults or {};
  package = backendDefaults.package or defaults.package or null;

  # `config` rides along so callbacks can observe sibling backend
  # options — e.g. the devenv materializer's conditional `devenv:files`
  # task edge needs `config.files != {}`.
  callbackArgs = {
    inherit cfg config mergedServers mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables moduleEnvironmentVariables mergedAgents mergedContext hasMergedContext resolvedSettings resolvedShell topHooks;
  };
  customConfig = backendConfigFn callbackArgs;
  migrationConfig = migrationConfigFn callbackArgs;
  # Repository AGENTS.md targets have one cross-runtime owner. Codex and Kiro
  # public file entries for those paths arbitrate inside sharedAgentsMd.nix;
  # letting their ordinary sinks lower the same target independently would
  # bypass whole-entry replacement and null tombstones at B7.
  sharedAgentsMdTargets =
    if backend == "devenv" && builtins.elem appRecord.name ["codex" "kiro"]
    then
      builtins.attrNames (
        lib.attrByPath ["ai" "internal" "agentsMd"] {} config
      )
    else [];
  runtimeSinkFiles = builtins.removeAttrs cfg.files sharedAgentsMdTargets;
  # ── Package installation ───────────────────────────────────────────────
  # Owned HERE, not by each factory. An enabled runtime installs SOMETHING
  # unless its backend spec opts out EXPLICITLY.
  #
  # The default is load-bearing: a backend spec that says nothing about
  # packages installs `cfg.package`. It used to be the reverse — installation
  # was a per-factory `home.packages` / `packages` write with no shared
  # requirement — and `claude` shipped with that write missing from BOTH
  # backends. Home Manager masked it (upstream's `programs.claude-code`
  # installs the package), so the only visible symptom was `claude` missing
  # from the devenv profile while every other runtime was fine. Silence now
  # means "install the plain package", so the same omission is inert.
  #
  # `installPackage` accepts the same callback args as `config`, so a factory
  # that wraps its binary derives the wrapper once and never repeats the
  # lowering. `null` is the documented opt-out and exists for exactly one
  # case — see mkClaude.nix's `hm` spec.
  installPackageFn = backendSpec.installPackage or (_: cfg.package);
  rawInstalledPackages =
    if installPackageFn == null
    then []
    else [(installPackageFn callbackArgs)];
  installedPackages =
    if options ? warnings
    then rawInstalledPackages
    else lib.foldr lib.warn rawInstalledPackages deliveryWarnings;
  # `home.packages` on Home Manager, `packages` on devenv. The two option
  # names are the whole reason this cannot live in the factories without
  # being written twice per runtime.
  packageInstallConfig =
    if backend == "hm"
    then {home.packages = installedPackages;}
    else {packages = installedPackages;};
in {
  options.ai.${appRecord.name} =
    {
      _ownPlans = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            declared = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
              description = "Per document path, the leaves this generation declares ownership of.";
            };
            plan = lib.mkOption {
              type = lib.types.anything;
              description = "The `own` plan this writer applies: `bash` plus the ordered targets.";
            };
          };
        });
        default = {};
        internal = true;
        visible = false;
        # `own` carries every target, unit, mode, ledger name and byte of
        # content as DATA in a store-resident plan, so an activation body names
        # none of them, and the plan FILE cannot be read back at eval —
        # importing a derivation is forbidden here, and discarding the plan's
        # string context to make it readable would drop the store references
        # that keep a rendered command alive in the generation's closure. This
        # is the only eval-visible record, and the module-eval checks read it
        # instead of splitting a heredoc out of generated shell.
        # `helpers.mkOwnBundle` emits this record AND the writer from one set of
        # arguments, so the two cannot drift; `declared` carries the one thing
        # the plan cannot, because `builtins.fromJSON` refuses a string that
        # refers to a store path.
        description = "Reconciliation plans this generation owns, keyed by the writer's entry name.";
      };
      activation = lib.mkOption {
        type = deliveryOptions.writerMapType;
        default = {};
        description = ''
          The writers that materialize ${appRecord.name}'s owned files, keyed
          by a name of your choosing. Each one declares the literal activation
          entry or devenv task it becomes, where it sits in that backend's
          ordering, and every ledger it has ever owned — so a surface that
          drops to zero files still emits the writer that retracts what the
          previous generation wrote. A writer that owns no files at all
          declares a `command` instead.
        '';
      };
      enable = lib.mkEnableOption appRecord.name;
      files = lib.mkOption {
        type = deliveryOptions.fileMapType;
        default = {};
        apply = runtimeFiles.validateFiles appRecord.name;
        description = ''
          Final static files owned by ${appRecord.name}, keyed by a path relative
          to the active backend root (HOME for Home Manager, project root for
          devenv), and described rather than lowered: each entry says what
          bytes it carries, the consumer facts that decide how it lands, and
          which writer owns it if it is not a symlink. `null` suppresses a
          generated entry. Generated CONTENT is contributed at `mkDefault`
          priority and every sibling field at ordinary priority, so a consumer
          can replace the bytes, change the method, or do one without the
          other.
        '';
      };
      methodFor = lib.mkOption {
        type = lib.types.functionTo (lib.types.enum deliveryMethod.methods);
        default = deliveryMethod.byRule;
        defaultText = lib.literalExpression "lib.ai.deliveryMethod.byRule";
        description = ''
          Resolves how a file lands for every entry of
          `ai.${appRecord.name}.files` that states no `method` of its own. It
          receives `{backend, path, facts, default}`, where `default` is the
          standard rule, so a replacement can override one case and DELEGATE
          the rest rather than restating the rule. Replacing it never means
          reimplementing ownership, deletion or pruning: those live below it,
          in the router and the reconciler, which this function never names.
          Two definitions of a function cannot merge, so this option is
          REPLACED with `lib.mkForce` and never added to; composing a
          per-file exception is what `method` on the entry is for.
        '';
      };
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
      _normalizedPools.mcpServers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        readOnly = true;
        internal = true;
        visible = false;
        description = "Internal normalized MCP-pool capability marker used by shared proxy ownership.";
      };
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
    # Both real backends expose warnings. Minimal evalModules callers without
    # that option still see diagnostics when they force the installed packages.
    (lib.optionalAttrs (options ? warnings) {warnings = deliveryWarnings;})
    {_module.args.aiTransformers = appRecord.transformers;}
    # Narrow compatibility cleanup may need to run on the generation that
    # disables a runtime. Product output remains solely inside cfg.enable.
    migrationConfig
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
    (lib.mkIf cfg.enable (lib.mkMerge [
      packageInstallConfig
      customConfig
      # The delivery layer's one lowering seam. Everything a runtime declares
      # about how its files land is read HERE, by the backend's adapter, so no
      # factory writes `home.file`, `home.activation`, `files` or `tasks`
      # itself.
      #
      # The adapter reads `cfg.files`, so the shared-AGENTS.md arbitration
      # hands it the stripped map rather than filtering behind its back.
      (adapters.${backend} {
        cfg = cfg // {files = runtimeSinkFiles;};
        inherit config;
        runtime = appRecord.name;
      })
    ]))
  ];
}
