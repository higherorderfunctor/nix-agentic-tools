# Shared backend transformer body. `lib.ai.app.hmTransform` and
# `devenvTransform` both select it in app/default.nix; the `backend` argument
# is the only thing that differs. One module owns the pool fold, the public
# normalized options, package installation and generated-file staging, and the
# runtime supplies one delivery callback shared by both backends.
#
# Input record shape: see mkRuntime.nix, which owns it. `checkRecord.nix`
# rejects a backend spec carrying anything but `installPackage`,
# `migrationConfig` and `options`, and a `poolOptions` key no pool option here
# reads, both there and here, because a record can reach this transform
# without passing mkRuntime. It also rejects a stray field in what the
# record's `sharedAgentsMd` callback returns. This body reads `<backend>`
# for those three and ignores the other backend's spec: `installPackage` and
# `migrationConfig` fall back to the record-level field, while `options` is
# merged over the record's shared `options` rather than replacing them.
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
  agent = import ../agent.nix {inherit lib;};
  aiCommon = import ../ai-common.nix {inherit lib;};
  aiTypes = import ../types.nix {inherit lib;};
  dirHelpers = import ../dir-helpers.nix {inherit lib;};
  generatedFiles = import ./generatedFiles.nix {
    inherit lib;
    inherit (appRecord) pkgs;
  };
  hooks = import ../hooks.nix {inherit lib;};
  jailLib = import ../jail {inherit lib;};
  pathProvenanceNotice = import ../runtime-path-provenance-notice.nix appRecord.pkgs;
  proxyLib = import ../proxy {inherit lib;};
  runtimeModule = import ../../../packages/ai-module/lib/runtime.nix;
  # `pkgs` comes off the RECORD, never from the module arguments. Naming
  # it in this function's formals makes the module system resolve it via
  # `_module.args`, which requires `config` and deadlocks against any
  # factory whose options use `pkgs.formats.json` as a freeform type —
  # see the note on `pkgs` in mkRuntime.nix.
  mcpProxy = import ../mcpProxy.nix {
    inherit lib;
    inherit (appRecord) pkgs;
  };
  cfg = config.ai.${appRecord.name};
  # Where the builder's option groups sit below `ai.<name>` (see
  # optionNamespaces.nix). Path operations read the record's namespaces
  # before backendSpec is forced, so they check the record themselves.
  namespaces = import ./optionNamespaces.nix {inherit lib;};
  checkedRecord = assert checkRecord.record appRecord; appRecord;
  hasLauncher = namespaces.hasLauncher checkedRecord;
  launcherPath = namespaces.launcher checkedRecord;
  poolsPath = namespaces.pools checkedRecord;
  launcherCfg = lib.attrByPath launcherPath {} cfg;
  poolCfg = lib.attrByPath poolsPath {} cfg;
  poolOptionsPath = namespaces.pool checkedRecord;
  # A pool's option name as a consumer writes it, for option descriptions.
  poolOptionName = pool: lib.showOption (["ai" appRecord.name] ++ poolOptionsPath pool ++ [pool]);
  normalizedPath = pool: poolOptionsPath pool ++ ["normalized" pool];
  placeNormalized = values:
    lib.foldl' lib.recursiveUpdate {} (lib.mapAttrsToList (pool: value:
      lib.setAttrByPath (normalizedPath pool) value)
    values);
  deliveryWarnings = import ../delivery-warnings.nix {inherit lib;} {
    inherit appRecord backend config;
    # Where this runtime's context and rules land, from its own path
    # bindings, and which of those paths the shared AGENTS.md owner holds.
    contentTargets = lib.optionalAttrs (appRecord ? contentTargets) (let
      result = appRecord.contentTargets callbackArgs;
    in
      assert checkRecord.contentTargets appRecord.name result; result);
    sharedTargets = sharedAgentsMdTargets;
    hasContext = normalizedHasContext;
    inherit generatedContent;
    generatedReplaced = generatedFiles.replaced {
      inherit (cfg) files;
      generated = generatedContent;
      inherit (generatedArgs) staged;
    };
  };
  supportedSurfaces = builtins.attrNames (lib.filterAttrs (_: support: support.backends != []) (appRecord.surfaceSupport or {}));
  supportsPool = poolName: builtins.elem poolName supportedSurfaces;
  # Per-runtime entries replace root entries atomically. For nullable pools,
  # null is filtered after precedence so it suppresses a same-key root entry.
  mergePool = poolName: topPool: cliPool:
    if supportsPool poolName
    then aiCommon.mergePool {inherit topPool cliPool;}
    else {};
  # Agents are layered when the runtime supplies a native agent record:
  #
  #   ai.agents.<n>                 normalized record, fanned out here
  #   ai.<runtime>.agents.<n>       normalized record, or a raw native file
  #   ai.<runtime>.native.agents.<n> typed native record: `agentTransformer`
  #                                 lowers each normalized record into it at
  #                                 mkDefault, so consumer fields win
  #
  # A raw file replaces the root record at its key and bypasses the native
  # layer; the runtime's delivery callback receives the raw files as
  # `rawAgents` and the native records as `nativeAgents`, already apart.
  # Without a native record every merged entry stays in the normalized pool
  # (`mergedAgents`), raw files included.
  hasNativeAgents = supportsPool "agents" && appRecord ? agentNativeType;
  agentsDirSuffixes = appRecord.agentsDirSuffixes or [".md"];
  poolAgents = mergePool "agents" config.ai.agents (poolCfg.agents or {});
  rawAgents = lib.optionalAttrs hasNativeAgents (lib.filterAttrs (_: value: !(agent.isSemantic value)) poolAgents);
  mergedAgents = removeAttrs poolAgents (builtins.attrNames rawAgents);
  mergedEnvironmentVariables = mergePool "environmentVariables" config.ai.environmentVariables (launcherCfg.environmentVariables or {});
  # Suppression applies after runtime entries replace root entries so a
  # runtime-local `enable = false` can retract an inherited root rule.
  mergedRules = lib.filterAttrs (_: aiCommon.hasContent) (mergePool "rules" config.ai.rules poolCfg.rules);
  # Proxy ownership is resolved at the declaration scope BEFORE fanout.
  # Top-level declarations contribute only their lowered credential-free
  # client entries here; sharedOptions.nix emits their one managed unit.
  # Runtime declarations lower independently and own their managed units
  # directly. Null tombstones survive lowering and are filtered by mergePool.
  topServers = mcpProxy.lowerClientEntries config.ai.mcpServers;
  runtimeServers = mcpProxy.lowerClientEntries poolCfg.mcpServers;
  mergedServers = mergePool "mcpServers" topServers runtimeServers;
  mergedSkills = mergePool "skills" config.ai.skills poolCfg.skills;

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
        cliValue = launcherCfg.shell or null;
      }
    else null;

  # Normalized settings narrow the root one field at a time. This is a
  # translation input only: factories render supported fields into their
  # native.settings option at mkDefault priority, and native option merging
  # arbitrates against consumer-authored values.
  resolvedSettings =
    if supportsPool "settings"
    then {
      reasoningEffort = aiCommon.resolveOverride {
        topValue = config.ai.settings.reasoningEffort;
        cliValue = poolCfg.settings.reasoningEffort;
      };
    }
    else {};

  # The proxy selection is one unit: a runtime selection replaces the root one
  # whole (`proxyLib.resolve`). Null when nothing is selected or the runtime
  # does not consume the pool.
  proxyInstances = proxyLib.instancesFor config;
  proxyCandidate =
    if supportsPool "proxy"
    then
      proxyLib.resolve {
        instances = proxyInstances;
        root = config.ai.proxy;
        runtime = poolCfg.proxy;
      }
    else
      proxyLib.resolve {
        instances = proxyInstances;
        root = config.ai.proxy;
        runtime = config.ai.proxy;
      };
  unsupportedAirlock = appRecord.name != "claude" && (proxyCandidate.owner or null) == "airlock";
  resolvedProxy =
    if !supportsPool "proxy" || unsupportedAirlock
    then null
    else proxyCandidate;

  # The jail folds field by field (`jailLib.resolve`). Null unless the result
  # enables it, or when the runtime does not consume the pool.
  resolvedJail =
    if supportsPool "jail"
    then
      jailLib.resolve {
        root = config.ai.jail;
        runtime = launcherCfg.jail;
      }
    else null;

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

  # A text-source record becomes the DEFAULT of a public normalized option,
  # so every field it carries becomes a definition at one priority. Two
  # consequences: its computed read-only fields would be defined twice, and
  # carrying both `text` and `source` would tie them — which throws, and
  # before throwing forces `text`, whose `apply` already read the source.
  # So only the winning arm crosses, chosen from the ORIGINAL record's
  # `_sourceWins`, which compares priorities without reading any bytes.
  toNormalizedTextSource = value:
    removeAttrs value (
      ["_enableDefined" "_sourceWins" "_textSourceType"]
      ++ (
        if aiTypes.textSourceUsesSource value
        then ["text"]
        else ["source"]
      )
    );
  contextValues = [config.ai.context poolCfg.context];
  # Presence must stay structural. `composeContent` reads source-backed bytes
  # when two values compose, so using `mergedContext != null` as a generator
  # gate would force a discarded default before B7 replacement or disable
  # arbitration.
  hasMergedContext =
    if supportsPool "context"
    then lib.any aiCommon.hasContent contextValues
    else false;
  mergedContext =
    if supportsPool "context"
    then aiCommon.composeContent contextValues
    else null;
  # A submodule value includes its computed read-only fields. When that value
  # becomes the default of the public normalized option, its type recomputes
  # those fields; carrying them across would define each read-only option twice.
  normalizedContext =
    if mergedContext == null
    then null
    else removeAttrs (toNormalizedTextSource mergedContext) ["filename"];
  topHooks =
    if supportsPool "hooks"
    then config.ai.hooks
    else {};

  # An evaluated record's text source carries both arms; only the winner
  # crosses into a pool or native default (see `toNormalizedTextSource`).
  normalizeAgent = value:
    if agent.isSemantic value
    then value // {instructions = toNormalizedTextSource value.instructions;}
    else value;
  normalizedAgents = lib.mapAttrs (_: normalizeAgent) mergedAgents;
  # Each field of a lowered record is its own mkDefault definition, so a
  # consumer who sets one field of `native.agents.<n>` overrides that field
  # and keeps the rest; a mkDefault on the whole record would be discarded.
  nativeAgentDefaults = lib.mapAttrs (name: value:
    lib.mapAttrs (_: lib.mkDefault) (appRecord.agentTransformer name (normalizeAgent value)))
  (lib.getAttrFromPath (normalizedPath "agents") cfg);
  # Kiro keeps its established runtime-local scalar `inclusion` override.
  # Root rules and every other runtime expose the portable priority list.
  # After root/runtime replacement has chosen one complete entry, normalize
  # Kiro's scalar (or null-derived matcher default) into that common list so
  # every emitter and shared AGENTS.md callback sees one rule shape.
  normalizedRules = lib.mapAttrs (_: rule:
    toNormalizedTextSource (rule
      // {
        inclusion = aiCommon.normalizeInclusion rule;
      }))
  mergedRules;

  # A whole-pool option default disappears when a consumer adds just one key.
  # Keep these folds as per-key definitions, so ordinary additions preserve
  # unrelated entries while a whole-pool mkForce still replaces everything.
  normalizedKeyedPools = {
    agents = normalizedAgents;
    environmentVariables = mergedEnvironmentVariables;
    mcpServers = mergedServers;
    rules = normalizedRules;
    skills = mergedSkills;
  };
  normalizedPools = {
    agents = {
      type = lib.types.attrsOf (
        if hasNativeAgents
        then agent.semanticAgentType
        else agent.agentType
      );
    };
    context = {
      default = normalizedContext;
      type = lib.types.nullOr aiCommon.optionalContentModule;
    };
    environmentVariables = {
      type = lib.types.attrsOf lib.types.str;
    };
    hooks = {
      apply = lib.filterAttrs (_event: blocks: blocks != []);
      default = topHooks;
      type = hooks.hooksType;
    };
    jail = {
      default = resolvedJail;
      type = jailLib.resolvedType;
    };
    # Proxy entries are already lowered here; applying the declaration schema
    # again would add defaults to the credential-free client record.
    mcpServers = {
      type = lib.types.attrsOf lib.types.raw;
    };
    proxy = {
      default = resolvedProxy;
      type = proxyLib.resolvedType;
    };
    rules = {
      type = lib.types.attrsOf aiCommon.ruleModule;
    };
    settings = {
      default = resolvedSettings;
      type = aiCommon.normalizedSettingsType;
    };
    shell = {
      default = resolvedShell;
      type = lib.types.nullOr lib.types.package;
    };
    skills = {
      type = lib.types.attrsOf lib.types.path;
    };
  };
  checkRecord = import ./checkRecord.nix {inherit lib;};
  # A nested launcher declares its harness switch beside its own options;
  # `ai.<name>.enable` is derived from that switch. A runtime without a
  # launcher keeps its switch at the root.
  enablePath = namespaces.enable checkedRecord;
  harnessSwitched = enablePath != ["enable"];
  runtimeOptions = (appRecord.options or {}) // backendOptions;
  # A runtime's own options may already declare `native.*` (settings), so the
  # native agent option joins that attrset rather than replacing it.
  nativeOptions =
    runtimeOptions
    // lib.optionalAttrs hasNativeAgents {
      native =
        (runtimeOptions.native or {})
        // {
          agents = lib.mkOption {
            type = lib.types.attrsOf appRecord.agentNativeType;
            default = {};
            description = ''
              Native ${appRecord.name} agent records, one file each. Every
              normalized agent that reaches ${appRecord.name} (root
              `ai.agents` and `${poolOptionName "agents"}`, after
              replacement and null withdrawal) lowers into the entry at its
              key at `mkDefault`, field by field, so a field defined here wins
              and runtime-only fields are added here. Define an entry field by
              field: an entry wrapped whole in `mkDefault` is discarded when a
              normalized agent exists at the same key, so a module default
              must set each field at `mkDefault` instead. An entry with no
              normalized counterpart is a native-only agent, including one
              whose normalized agent was withdrawn with null. A raw file at
              `${poolOptionName "agents"}.<name>` bypasses this layer and
              cannot share its key.
            '';
          };
        };
    };
  # A per-runtime pool option the builder declares for a supported pool, with
  # the record's `poolOptions.<pool>` merged over it, so a runtime states only
  # what differs, such as its own description. `agents` takes no override
  # (checkRecord rejects one): a runtime appends its own sentence through
  # `agentsDescriptionSuffix` and supplies its `native.agents` type as
  # `agentNativeType`. Every runtime with the agents pool gets `agentsDir`,
  # which expands into raw `agents` entries with the record's
  # `agentsDirSuffixes`.
  poolOptions = appRecord.poolOptions or {};
  poolOption = pool: declaration:
    lib.optionalAttrs (supportsPool pool) {
      ${pool} = lib.mkOption ({default = {};} // declaration // poolOptions.${pool} or {});
    };
  normalizedOptions = placeNormalized (lib.mapAttrs (pool: spec:
    lib.mkOption (spec
      // {
        default = spec.default or {};
        defaultText = lib.literalExpression (
          if normalizedKeyedPools ? ${pool}
          then "{}"
          else "the root-to-runtime ${pool} fold"
        );
        internal = false;
        readOnly = false;
        description = ''
          Merged ${pool} consumed by ${appRecord.name}'s transformer. The
          supported root-to-runtime fold supplies per-key defaults after
          replacement and tombstone filtering for keyed pools, so ordinary
          additions preserve unrelated inherited keys. Other pools default
          to the fold as a whole. Use `lib.mkForce` on this ordinary option
          to replace the transformer's input.
        '';
      })) (lib.filterAttrs (pool: _: supportsPool pool) normalizedPools));
  # Only a launcher's own options sit at its path, so a reserved namespace
  # without a launcher declares nothing there.
  launcherOwnOptions =
    lib.optionalAttrs hasLauncher {
      package = lib.mkOption ({
          type = lib.types.nullOr lib.types.package;
          default = package;
          description = "The ${appRecord.name} package, or null to configure the runtime without installing it.";
        }
        // lib.optionalAttrs (packageText != null) {defaultText = packageText;});
    }
    // poolOption "environmentVariables" {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      description = "Environment variables baked into the ${appRecord.name} launcher wrapper. Scoped to the ${lib.toSentenceCase appRecord.name} process and the commands it spawns; never exported into the project shell. Null suppresses a root entry at the same key.";
    }
    // lib.optionalAttrs (supportsPool "jail") {
      jail = lib.mkOption {
        type = lib.types.submodule {options = jailLib.fields;};
        default = {};
        description = ''
          ${appRecord.name}'s bubblewrap jail. Each non-null field replaces
          the matching `ai.jail` field for this runtime; null inherits it.
          The resolved jail is `${lib.showOption (["ai" appRecord.name] ++ normalizedPath "jail")}`.
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
    };
  launcherOptions =
    lib.recursiveUpdate
    (lib.setAttrByPath enablePath (lib.mkEnableOption appRecord.name))
    (lib.optionalAttrs (launcherOwnOptions != {}) (lib.setAttrByPath launcherPath launcherOwnOptions));
  # Option attrsets merge by key, but an option itself is a leaf: a runtime's
  # own option at a pool's key replaces the builder's, as `//` would.
  mergeOptionTrees = lib.recursiveUpdateUntil (_: lhs: rhs: !(builtins.isAttrs lhs && builtins.isAttrs rhs) || lib.isOption lhs || lib.isOption rhs);
  # The per-runtime pool options, placed at the record's pools namespace.
  poolDeclarations =
    lib.optionalAttrs (supportsPool "mcpServers") {
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        }));
        default = {};
        description = "${appRecord.name}-specific MCP servers. Entries replace top-level ai.mcpServers at the same key; null suppresses an inherited server.";
      };
    }
    // poolOption "agents" {
      type = lib.types.attrsOf (lib.types.nullOr agent.agentType);
      description =
        "${appRecord.name}-specific agents: a normalized record or a raw native file. Entries replace top-level ai.agents at the same key; null suppresses an inherited agent."
        + lib.optionalString hasNativeAgents " Normalized records lower into `ai.${appRecord.name}.native.agents`; raw files bypass that layer. Null withdraws only the normalized record: a `native.agents` entry at the same key still ships as a native-only agent."
        + lib.optionalString (appRecord ? agentsDescriptionSuffix) " ${appRecord.agentsDescriptionSuffix}";
    }
    // lib.optionalAttrs hasAgentsDir {
      agentsDir = lib.mkOption ({
          type = lib.types.nullOr aiCommon.dirOptionType;
          default = null;
          description = "Directory of native agent files (${lib.concatStringsSep ", " agentsDirSuffixes}), expanded into raw `${poolOptionName "agents"}` entries keyed by basename minus the suffix. Accepts a path, a path-like string or derivation, or `{ path, filter? }`. Only top-level regular files with those suffixes are expanded; subdirectories and other files are not delivered, and two files with one stem fail evaluation. They blend with named entries; a named entry at the same key wins.";
        }
        // poolOptions.agentsDir or {});
    }
    // lib.optionalAttrs (supportsPool "proxy") {
      proxy = lib.mkOption {
        type = lib.types.submodule {
          options = proxyLib.runtimeOptions;
        };
        default = {};
        description = ''
          ${appRecord.name}'s proxy selection. When it selects anything
          (a `url` or an `instance`), it replaces `ai.proxy`'s selection as a whole for this
          runtime; otherwise the root selection applies. The resolved
          endpoint is `${lib.showOption (["ai" appRecord.name] ++ normalizedPath "proxy")}`.
          Through an instance, `allow` and `providers` limit what the key
          may reach.
        '';
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
          `ai.${appRecord.name}.native.settings`, including an explicit null,
          to arbitrate against the derived value.
        '';
      };
    }
    // lib.optionalAttrs (supportsPool "context") {
      context = lib.mkOption {
        type = aiCommon.runtimeContextModule (appRecord.contextFilename or (throw "${appRecord.name}: supportedSurfaces includes context but the app record has no contextFilename"));
        default = {};
        description =
          appRecord.contextDescription or ''
            ${appRecord.name}-specific context appended after `ai.context` in
            the runtime's single always-on `${appRecord.contextFilename}` file.
            When `text` and `source` are defined at different module priorities,
            the higher-priority definition supplies the content whichever field
            it targets; definitions at the same priority conflict. Same-priority
            `text` definitions concatenate in module order. Enabled context must
            resolve to non-empty `text` or a `source`. Set `enable = false` to
            omit this context. `filename` controls the native artifact name.
          '';
      };
    }
    // lib.optionalAttrs (supportsPool "rules") {
      rules = lib.mkOption {
        type = lib.types.attrsOf (appRecord.ruleModule or aiCommon.ruleModule);
        default = {};
        description =
          appRecord.rulesDescription or ''
            ${appRecord.name}-specific rules. Entries replace top-level ai.rules
            at the same key; set `enable = false` to suppress an inherited rule.
            Same-priority `text` definitions concatenate in module order.
            Enabled rules must resolve to non-empty `text` or a `source`.
          '';
      };
      rulesDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory of `.md` rule files. Each
          file becomes one entry in `${poolOptionName "rules"}` keyed by
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
          `${poolOptionName "skills"}` keyed by the subdir name.
          Accepts a path literal or `{ path, filter? }`.
        '';
      };
    };
  hasAgentsDir = supportsPool "agents";
  normalizedPool = name: neutral:
    if supportsPool name
    then lib.getAttrFromPath (normalizedPath name) cfg
    else neutral;
  # A default context can compose source bytes. Keep its presence structural
  # until final-file priority arbitration has kept that generated content.
  # An explicit normalized override instead supplies its own presence.
  normalizedHasContext =
    if !supportsPool "context"
    then false
    else if (lib.getAttrFromPath (normalizedPath "context") options.ai.${appRecord.name}).highestPrio == 1500
    then hasMergedContext
    else aiCommon.hasContent (lib.getAttrFromPath (normalizedPath "context") cfg);

  # A record can reach this transform without passing mkRuntime (an override
  # of an exported record, or a hand-built one), so its closed fields are
  # checked again here. Every backend-specific read goes through
  # `backendSpec`, and `backendOptions` is forced by every evaluation.
  backendSpec = assert checkRecord.record appRecord;
    appRecord.${backend} or {};
  backendOptions = backendSpec.options or {};
  # Delivery is described once, on the record. Installation and migration
  # default to the record too, and a backend spec overrides either one.
  configFn = appRecord.config or (_: {});
  migrationConfigFn = backendSpec.migrationConfig or appRecord.migrationConfig or (_: {});

  package = (appRecord.defaults or {}).package or null;
  # The package option's defaultText, when the record states one. Without it
  # the options documentation renders the default by evaluating the package.
  packageText = (appRecord.defaults or {}).packageText or null;

  # `config` rides along so callbacks can observe sibling backend options.
  #
  # `backend` rides along for the one callback shared by both: a runtime whose
  # delivery differs only in a consumer FACT states the fact per backend and
  # never reads this, but a surface one backend genuinely does not have — a
  # document only Home Manager reconciles, a path only the project tree has —
  # has to be able to say so.
  #
  # `launcherEnvironment` is everything a launcher bakes into its runtime's
  # own process, merged in ONE order for every runtime: module defaults, then
  # `SHELL` from the resolved shell, then the consumer's pool LAST, so an
  # explicit entry (`environmentVariables.SHELL` included) wins. Claude has
  # no launcher and lowers the parts into `settings.env` instead.
  callbackArgs = {
    inherit backend cfg config moduleEnvironmentVariables options;
    normalized = lib.genAttrs supportedSurfaces (pool: lib.getAttrFromPath (normalizedPath pool) cfg);
    launcherEnvironment =
      moduleEnvironmentVariables
      // lib.optionalAttrs (callbackArgs.resolvedShell != null) {
        SHELL = lib.getExe callbackArgs.resolvedShell;
      }
      // callbackArgs.mergedEnvironmentVariables;
    hasMergedContext = normalizedHasContext;
    mergedAgents = normalizedPool "agents" {};
    inherit rawAgents;
    nativeAgents = lib.optionalAttrs hasNativeAgents cfg.native.agents;
    mergedContext = normalizedPool "context" null;
    mergedEnvironmentVariables = normalizedPool "environmentVariables" {};
    mergedRules = normalizedPool "rules" {};
    mergedServers = normalizedPool "mcpServers" {};
    mergedSkills = normalizedPool "skills" {};
    resolvedJail = normalizedPool "jail" null;
    resolvedProxy = normalizedPool "proxy" null;
    resolvedSettings = normalizedPool "settings" {};
    resolvedShell = normalizedPool "shell" null;
    topHooks = normalizedPool "hooks" {};
  };
  customConfig = configFn callbackArgs;
  # A runtime that reads the repository AGENTS.md contributes to its one
  # owner (sharedAgentsMd.nix) on devenv: its merged context plus the rules,
  # index entries and limit its record's `sharedAgentsMd` callback returns, each runtime
  # keeping its own rule policy. The key is published whether or not it has
  # content, for observers such as delivery-warnings.nix. A limit is published
  # with it too, because the runtime reads the file whoever wrote it.
  sharedAgentsMdConfig = lib.optionalAttrs (backend == "devenv" && appRecord ? sharedAgentsMd) (let
    # Read by field, so a stray one is rejected rather than dropped.
    shared = let
      result = appRecord.sharedAgentsMd callbackArgs;
    in
      assert checkRecord.sharedAgentsMd appRecord.name result; result;
    index = shared.index or {};
    rules = shared.rules or {};
    hasContent = normalizedHasContext || index != {} || rules != {};
  in {
    ai.internal.agentsMdTargets.${appRecord.name} = shared.key;
    ai.internal.agentsMd = lib.mkIf (hasContent || shared ? maxBytes) {
      ${shared.key} =
        {
          # A limit alone must yield to content another runtime supplies.
          hasContent =
            if hasContent
            then true
            else lib.mkDefault false;
          audiences = lib.genAttrs (lib.attrNames (index // rules)) (_: [appRecord.name]);
          inherit index rules;
        }
        // lib.optionalAttrs (shared.hasOnDemandIndex or false) {hasOnDemandIndex = true;}
        // lib.optionalAttrs (shared ? maxBytes) {inherit (shared) maxBytes;}
        // lib.optionalAttrs normalizedHasContext {
          context = aiCommon.readContent callbackArgs.mergedContext;
        };
    };
  });
  migrationConfig = migrationConfigFn callbackArgs;
  # Repository AGENTS.md targets have one cross-runtime owner. Public file
  # entries for those paths arbitrate with the composer at layer 2;
  # letting their ordinary sinks lower the same target independently would
  # bypass whole-entry replacement and explicit disable at B7.
  sharedAgentsMdTargets =
    if backend == "devenv"
    then
      builtins.attrNames (
        lib.attrByPath ["ai" "internal" "agentsMd"] {} config
      )
    else [];
  # `S` → `R`: the staged entries become layer-1 definitions over the
  # runtime's one generated tree. Disabled runtimes never read `S`.
  generatedArgs = {
    staged = cfg._generatedFiles;
    tree = cfg._generatedTree;
  };
  generatedContent = generatedFiles.content generatedArgs;
  # ── Package installation ───────────────────────────────────────────────
  # Owned HERE, not by each factory. An enabled runtime installs something by
  # default; an explicit `package = null` keeps configuration enabled without
  # installing a package.
  #
  # The default is load-bearing: a record that says nothing about packages
  # installs `launcherCfg.package`. It used to be the reverse — installation
  # was a per-factory `home.packages` / `packages` write with no shared
  # requirement — and `claude` shipped with that write missing from BOTH
  # backends, visible only as `claude` missing from the devenv profile while
  # every other runtime was fine. Silence now means "install the plain
  # package", so the same omission is inert. The explicit null opt-out does
  # not call the factory callback, so package-wrapping factories never need to
  # accept null.
  #
  # `installPackage` accepts the same callback args as `config`, so a factory
  # that wraps its binary derives the wrapper once and never repeats the
  # lowering.
  launcherPackage =
    if hasLauncher
    then launcherCfg.package
    else null;
  installPackageFn = backendSpec.installPackage or appRecord.installPackage or (_: launcherPackage);
  # The jail wraps the FINISHED launcher, outermost and in place, so every
  # factory wrapper's baked environment and launch-time steps run inside it
  # and the command keeps its name. bubblewrap is Linux-only: elsewhere an
  # enabled jail lowers nothing and warns.
  # A value forced onto the normalized option still needs `enable = true`.
  jailRequested = launcherPackage != null && (callbackArgs.resolvedJail.enable or null) == true;
  jailLowers = appRecord.pkgs.stdenv.hostPlatform.isLinux;
  jailWarnings =
    lib.optional (cfg.enable && jailRequested && !jailLowers)
    "${poolOptionName "jail"} is enabled but bubblewrap is Linux-only; nothing is jailed on ${appRecord.pkgs.stdenv.hostPlatform.system}.";
  jailPackage = package:
    if jailRequested && jailLowers
    then
      jailLib.wrap {
        inherit (appRecord) executables name pkgs;
        inherit package;
        jail = config.ai.internal.jail;
        profile = callbackArgs.resolvedJail;
      }
    else package;
  rawInstalledPackages = lib.optional (launcherPackage != null) (jailPackage (installPackageFn callbackArgs));
  transformWarnings = deliveryWarnings ++ jailWarnings;
  installedPackages =
    if options ? warnings
    then rawInstalledPackages
    else lib.foldr lib.warn rawInstalledPackages transformWarnings;
  # `home.packages` on Home Manager, `packages` on devenv. The two option
  # names are the whole reason this cannot live in the factories without
  # being written twice per runtime.
  packageInstallConfig =
    if backend == "hm"
    then {home.packages = installedPackages;}
    else
      {packages = installedPackages;}
      // lib.optionalAttrs (options ? enterShell) {
        enterShell = lib.mkIf (launcherPackage != null) (let
          runtime = builtins.baseNameOf (lib.getExe launcherPackage);
        in ''
          ${lib.getExe pathProvenanceNotice} ${lib.escapeShellArg runtime} "$(command -v ${lib.escapeShellArg runtime} || :)" "''${DEVENV_PROFILE:-}"
        '');
      };
in {
  # Layer 1: `ai.<runtime>.files` forwards to `ai.files` while enabled; the
  # shared AGENTS.md keys forward without a claim, since their composer owns
  # them.
  imports = [
    (runtimeModule {
      enabled = cfg.enable;
      inherit (appRecord) name;
      shared = sharedAgentsMdTargets;
    })
  ];

  options.ai.${appRecord.name} = lib.recursiveUpdate (
    {
      _generatedFiles = generatedFiles.stagedOption;
      _generatedTree = generatedFiles.generatedTreeOption;
      _maxBytes = generatedFiles.maxBytesOption;
      checks = lib.genAttrs generatedFiles.surfaces (surface:
        lib.mkOption {
          type = lib.types.lines;
          default = config.ai.checks.${surface};
          defaultText = "config.ai.checks.${surface}";
          description = ''
            Shell snippet checking ${surface} files in ${appRecord.name}'s
            built runtime tree. It replaces `ai.checks.${surface}` when
            defined; splice `''${config.ai.checks.${surface}}` into this value
            to compose them. The snippet runs with `AI_RUNTIME` set to
            `${appRecord.name}` and target-relative paths in `"$@"`.
          '';
        });
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
    // lib.optionalAttrs harnessSwitched {
      enable = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        description = ''
          Whether ${appRecord.name} is managed. Read-only: true when
          `${lib.showOption (["ai" appRecord.name] ++ enablePath)}` is set.
        '';
      };
    }
    // lib.optionalAttrs (supportsPool "mcpServers") {
      _normalizedPools.mcpServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["ai" appRecord.name] ++ poolOptionsPath "mcpServers" ++ ["mcpServers"];
        readOnly = true;
        internal = true;
        visible = false;
        description = "Internal normalized MCP-pool capability marker used by shared proxy ownership: the option path of this runtime's MCP pool.";
      };
    }
    // mergeOptionTrees (lib.setAttrByPath poolsPath poolDeclarations) nativeOptions
  ) (lib.recursiveUpdate launcherOptions normalizedOptions);

  config = lib.mkMerge [
    # Both real backends expose warnings. Minimal evalModules callers without
    # that option still see diagnostics when they force the installed packages.
    (lib.optionalAttrs (options ? warnings) {warnings = transformWarnings;})
    (lib.optionalAttrs harnessSwitched {
      ai.${appRecord.name}.enable = launcherCfg.enable;
    })
    {
      ai.${appRecord.name} = placeNormalized (
        lib.mapAttrs (_: pool: lib.mapAttrs (_: lib.mkDefault) pool)
        (lib.filterAttrs (pool: _: supportsPool pool) normalizedKeyedPools)
      );
    }
    (lib.optionalAttrs hasNativeAgents {
      ai.${appRecord.name}.native.agents = nativeAgentDefaults;
    })
    # Outside the enable gate, like every fanout validation: an invalid
    # selection must not hide behind a disabled runtime.
    (lib.optionalAttrs (supportsPool "proxy" && options ? assertions) {
      assertions = proxyLib.assertionsFor proxyInstances (["ai" appRecord.name] ++ poolOptionsPath "proxy" ++ ["proxy"]) poolCfg.proxy;
    })
    (lib.optionalAttrs (options ? assertions) {
      assertions = [
        {
          assertion = !cfg.enable || !unsupportedAirlock;
          message = "ai.${appRecord.name}.proxy: Airlock selections currently support Claude Code only.";
        }
      ];
    })
    (lib.optionalAttrs (hasNativeAgents && options ? assertions) {
      assertions = let
        shared = builtins.attrNames (builtins.intersectAttrs rawAgents cfg.native.agents);
      in [
        {
          assertion = !cfg.enable || shared == [];
          message = "ai.${appRecord.name}.native.agents ${lib.concatStringsSep ", " shared}: ${poolOptionName "agents"} sets a raw native file at the same key, which bypasses the native layer. Keep one of the two.";
        }
      ];
    })
    # Narrow compatibility cleanup may need to run on the generation that
    # disables a runtime. Product output remains solely inside cfg.enable.
    migrationConfig
    # L2b → L3 fanout for per-CLI Dir options. Expansion happens
    # unconditionally (no mkIf cfg.enable) so the normalized option value is
    # complete even when the CLI is disabled. Actual on-disk emission remains
    # gated by `cfg.enable` inside the per-CLI factory's customConfig.
    (lib.optionalAttrs (supportsPool "rules") (lib.mkIf (poolCfg.rulesDir != null) {
      ai.${appRecord.name} = lib.setAttrByPath (poolsPath ++ ["rules"]) (lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.rulesFromDir poolCfg.rulesDir
      ));
    }))
    (lib.optionalAttrs hasAgentsDir (lib.mkIf (poolCfg.agentsDir != null) {
      ai.${appRecord.name} = lib.setAttrByPath (poolsPath ++ ["agents"]) (lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.agentsFromDirWith agentsDirSuffixes poolCfg.agentsDir
      ));
    }))
    (lib.optionalAttrs (supportsPool "skills") (lib.mkIf (poolCfg.skillsDir != null) {
      ai.${appRecord.name} = lib.setAttrByPath (poolsPath ++ ["skills"]) (lib.mapAttrs (_: lib.mkDefault) (
        dirHelpers.skillsFromDir poolCfg.skillsDir
      ));
    }))
    (lib.mkIf cfg.enable (lib.mkMerge [
      packageInstallConfig
      customConfig
      sharedAgentsMdConfig
      {ai.${appRecord.name}.files = generatedFiles.layer1 generatedArgs;}
    ]))
    {
      ai.${appRecord.name}._generatedTree =
        if cfg.enable
        then
          generatedFiles.tree {
            inherit backend config;
            inherit (cfg) checks;
            entries = generatedFiles.treeEntries {
              inherit (config.ai) files;
              inherit (generatedArgs) staged;
            };
            maxBytes = cfg._maxBytes;
            runtime = appRecord.name;
          }
        else null;
    }
  ];
}
