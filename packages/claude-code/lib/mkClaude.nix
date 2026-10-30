# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
{
  lib,
  pkgs,
  ...
}: let
  inherit (lib.ai) agent;
  sharedHooks = lib.ai.hooks;
  # Eval-pure reads of committed facts (no IFD). See overlays.md
  # § IFD Patterns and memory project_claude_effort_pin_state.
  claudeFact = let
    extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  in
    extracted.get (extracted.load {dir = ../extracted;}).aggregate;
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  openKeys = import ../../../lib/open-keys {inherit lib;};

  # The `native.settings` option surface: one option per path in the packaged
  # binary's own settings schema, merged with the hand-authored exceptions.
  # `.report` is what packages/claude-code/checks/claude-settings-schema.nix asserts on, so an
  # exception aimed at a key the binary no longer declares fails CI rather than
  # sitting here unnoticed.
  nativeFileSurface = import ./nativeOptions.nix {
    inherit claudeFact lib pkgs;
  };

  # Inspect the document both backends write. Unknown keys stay available for
  # forward compatibility; diagnostics belong at config level, outside type merge.
  nativeFileWarnings = cfg:
    (openKeys.inspect {
      known = openKeys.fromPaths {
        inherit (nativeFileSurface.settings) paths;
        names = nativeFileSurface.settings.publicKeys ++ nativeFileSurface.settings.internalKeys;
      };
      # The tree actually written — identical to the
      # `aiCommon.filterNulls cfg.native.settings` settings document below.
      # Filtering FIRST is load-bearing: a typed sub-option sitting at its
      # `null` default would otherwise report itself the day upstream renames
      # that key, for every consumer, including ones who never set it.
      value = aiCommon.filterNulls cfg.native.settings;
      allowed = cfg.allowUnrecognizedSettings;
      optionPath = ["ai" "claude" "native" "settings"];
      allowOptionPath = ["ai" "claude" "allowUnrecognizedSettings"];
      # Keys THIS MODULE writes are reported against the option that writes
      # them, so a binary that drops one does not read as consumer error.
      # Deliberately not an exemption — an exemption would suppress exactly the
      # drift signal worth having.
      notes = let
        ownWrite = opt: "this module writes this key itself, from `${opt}` — the\n      packaged binary no longer declares it. Clear that option, or bump\n      the package and its extracted sidecar together.";
      in {
        effortLevel = ownWrite "ai.settings.reasoningEffort";
        enableWorkflows = ownWrite "ai.claude.ultracodeOnLaunch";
        env = ownWrite "ai.shell / ai.environmentVariables";
        mcpServers = "MCP servers do not belong in settings.json — declare them\n      under `ai.mcpServers` or `ai.claude.mcpServers`, which render into\n      the project .mcp.json (devenv) or the Home Manager personal plugin.";
        ultracode = ownWrite "ai.claude.ultracodeOnLaunch";
      };
    }).warnings;

  # A single handler. `command` is modelled fully; the exotic handler types
  # (http/prompt/agent/mcp_tool) round-trip via the freeform JSON tail.
  hookHandler = lib.types.submodule {
    freeformType = (pkgs.formats.json {}).type;
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["command" "http" "prompt" "agent" "mcp_tool"];
        default = "command";
        description = "Handler type. Only `command` is modelled fully; other types round-trip via the freeform tail.";
      };
      command = lib.mkOption {
        # A package coerces to its executable store path, so its supporting
        # files ride the closure at absolute paths: Claude runs hooks with
        # cwd = project root, where relative companion paths are unsafe.
        type = lib.types.nullOr sharedHooks.commandType;
        default = null;
        description = ''
          For `type = "command"`: the executable to run. A package (coerced to
          its getExe path — supporting files ride the store closure) or a string.
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Per-handler timeout in seconds. Lowered into settings.json.";
      };
    };
  };
  # One matcher block within an event: an optional matcher + its handlers.
  hookMatcherBlock = sharedHooks.mkMatcherBlockType {
    handler = hookHandler;
    hooks = "Handlers that fire for this matcher block.";
    matcher = "Tool-name matcher (exact name or JS regex). Null for events that take no matcher (Stop, UserPromptSubmit, …).";
  };
  # Agent-memory collision guard — one PreToolUse entry.
  #
  # The `matcher` is what keeps this cheap: the hook is only spawned for Write and
  # Edit, and the script's own path test then drops everything outside a memory
  # directory. Both filters are needed — the matcher cannot see file paths, and the
  # path test cannot see which tool asked.
  #
  # The matcher is a REGEX and is not anchored, so `Edit` also catches `MultiEdit`
  # and `NotebookEdit`. That is left deliberately wide: every one of them can create
  # a memory file, the path test is the real gate, and a tool name added upstream
  # should fail toward being guarded rather than toward slipping through.
  #
  # Emitted as an `ai.claude.hooks` DEFINITION rather than as that option's
  # `default`: an option default is discarded wholesale once a consumer defines the
  # option at all, whereas a definition list-merges with consumer entries on the
  # same event.
  memoryCollisionGuardHooks = guard: let
    bin = lib.getExe (import ./memoryCollisionGuard.nix {
      inherit lib pkgs;
      inherit (guard) windowMinutes listCount extraDirectories;
    });
  in {
    PreToolUse = [
      {
        matcher = "Write|Edit";
        hooks = [{command = bin;}];
      }
    ];
  };

  # `ai.shell` / `ai.claude.shell` → settings.json `env.CLAUDE_CODE_SHELL`.
  # Claude is the one runtime here with a DEDICATED variable; it does not
  # read `SHELL` for this (measured: an explicit `SHELL=/usr/bin/zsh` is
  # ignored), which is exactly why the shared `ai.environmentVariables`
  # pool cannot implement this option and a typed one is needed.
  #
  # `env` is not a normalized settings key — it rides the native freeform
  # JSON tail — so this composes with a consumer's other `native.settings.env` entries rather
  # than replacing the attrset. mkDefault keeps an explicit
  # `ai.claude.native.settings.env.CLAUDE_CODE_SHELL` winning over the option.
  #
  # NOTE for anyone debugging a shell that did not take effect: Claude
  # SILENTLY falls back when the path is not executable — no warning, exit
  # 0, and it resolves its own bash instead. A package-typed option makes
  # that unreachable through this path, but a hand-written settings string
  # can still hit it.
  #
  # Identical on both backends because both write the same settings tree,
  # so it is defined once here rather than duplicated per callback.
  # Claude settings env beats process env, so both the typed shell and the
  # module-contributed sandbox-safe SSH command ride settings.json. The optional
  # proxy launcher only clears the inherited API-key descriptor before startup.
  #
  # mkDefault keeps an explicit `ai.claude.native.settings.env.<KEY>` winning, which
  # is the same precedence the wrapper harnesses get by merging module
  # defaults UNDER the consumer's pool.
  shellSettings = {
    resolvedShell,
    moduleEnvironmentVariables,
  }:
    lib.mkMerge [
      (lib.mkIf (resolvedShell != null) {
        ai.claude.native.settings.env.CLAUDE_CODE_SHELL =
          lib.mkDefault (lib.getExe resolvedShell);
      })
      {
        ai.claude.native.settings.env =
          lib.mapAttrs (_: lib.mkDefault) moduleEnvironmentVariables;
      }
    ];

  # Where each unit lands, shared by the staged entries below and
  # `contentTargets`, so the disabled-file warning names the path really staged.
  contextPath = cfg: ".claude/${cfg.context.filename}";
  rulePath = name: ".claude/rules/${name}.md";
  # One staged file (`ai.claude._generatedFiles`): its bytes, the codec they
  # are formatted with, and the surface whose checks they run.
  staged = surface: format: content: {inherit content format surface;};
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  claudeInference = import ./inference.nix {inherit lib pkgs;};
  pluginLib = import ./plugin.nix {inherit lib pkgs;};

  # The Home Manager personal plugin that carries MCP servers. Its directory
  # name is ours; the manifest name `hm` is the MCP tool namespace
  # (`mcp__plugin_hm_<server>`), kept short for token cost and stable for
  # consumers that pin tool names.
  personalPlugin = "home-manager";
  personalPluginManifest = "hm";
  # The generic `toolPolicy` as Claude permission rules, named the way Claude
  # names the tool: plugin-scoped for the Home Manager personal plugin, plain
  # for the project `.mcp.json`.
  claudeToolRules = {
    auto = "allow";
    disabled = "deny";
    prompt = "ask";
  };
  claudeToolName = isHm: row:
    if isHm
    then "mcp__plugin_${personalPluginManifest}_${row.server}__${row.tool}"
    else "mcp__${row.server}__${row.tool}";

  # Claude Markdown surfaces, one `.claude/<dir>/<name>.md` each. A path-like
  # value (path, store string, derivation) is linked as a `source`, anything
  # else is the file's text.
  markdownFiles = dir: values:
    lib.mapAttrs' (name: value:
      lib.nameValuePair ".claude/${dir}/${name}.md" (
        if dir == "agents"
        then staged "agents" "markdown" (agent.renderFile true name value)
        else staged "context" "markdown" (agent.fileContent value)
      ))
    values;
  # Declared per backend below: a backend's `native` options replace the shared
  # ones whole, and Home Manager's also carry `installMethod` and
  # `unpinLaunchEffort`.
  nativeSettingsOption = lib.mkOption {
    type = lib.types.submodule {
      freeformType = (pkgs.formats.json {}).type;
      # Generated from the packaged binary's own settings schema, merged
      # with the hand-authored exceptions — see nativeOptions.nix.
      inherit (nativeFileSurface) options;
    };
    default = {};
    description = ''
      Claude's settings.json, as typed options plus a freeform
      passthrough. Every key the packaged binary's own settings schema
      declares (extracted into the drift-checked
      packages/claude-code/extracted/, settings.paths) gets a typed option
      automatically; a short hand-authored list overrides the generated
      type where the schema is not the surface we want (`attribution.*`
      accepts a bool, `model` is a soft enum, `tui` carries a
      read-only-store caveat). Null typed keys are filtered out before
      the document is written, so an option left at its default writes
      nothing.

      The freeform catch-all still accepts a key newer than this
      package's schema. Unrecognized keys warn with spelling suggestions;
      `allowUnrecognizedSettings` suppresses selected warnings. The `ultracode`
      key is intentionally NOT a hand-authored option (see
      ultracodeOnLaunch) but is declared by the binary and so is typed
      like any other.
    '';
  };
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
    inherit pkgs;
    name = "claude";
    contextFilename = "CLAUDE.md";
    executables = ["claude"];
    inherit (claudeInference) installPackage;
    surfaceSupport = {
      agents = {};
      context = {};
      environmentVariables = {
        backends = [];
        reason = "Claude excludes the environmentVariables pool; native.settings.env is delivered through settings instead.";
      };
      hooks = {};
      jail = {};
      mcpServers = {};
      rules = {};
      settings.fields = ["inference" "reasoningEffort"];
      shell = {};
      skills = {};
    };
    defaults = {
      package = pkgs.ai.claude-code;
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "claude-code";
    };
    agentsDescriptionSuffix = "Each lands at `.claude/agents/<name>.md` under the backend root (`~` for Home Manager, the project for devenv).";
    # Shared options (present in both backends)
    options = {
      plugins = lib.mkOption {
        type = with lib.types; attrsOf (either package path);
        default = {};
        description = ''
          Claude plugins, keyed by plugin directory name. The value is
          either a path to a plugin directory or a package derivation.
          Each lands as ONE directory link at
          `~/.claude/skills/<name>`, which Claude Code 2.1.157+ loads as a
          personal plugin; a source without `.claude-plugin/plugin.json`
          gets one synthesized with `name = "<name>"`.

          The ATTRIBUTE NAME is load-bearing: it is the on-disk directory
          name and the synthesized manifest `name`, so it must not collide
          with an `ai.skills` name or the `home-manager` personal
          plugin (asserted). Attrset-only, so a bare flake-input store path
          never yields an unstable `<hash>-source` name.

          Home Manager only — personal plugins are user-scope, so devenv
          warns when this option is non-empty.
        '';
        example = lib.literalExpression ''
          {
            my-local-plugin = ./my-local-plugin;
            remember = inputs.claude-remember;
          }
        '';
      };
      allowUnrecognizedSettings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["someBrandNewKey"];
        description = ''
          Dotted paths under `native.settings` whose unrecognized-key warnings
          are suppressed.

          The freeform tail of `native.settings` exists so a key upstream ships
          today is settable today. Its cost is that a TYPO is shaped exactly
          like a brand-new key — and Claude ignores an unknown settings key
          silently, so a misspelling looks applied and does nothing. Every key
          the binary's own extracted schema
          (packages/claude-code/extracted/, settings.paths) does not declare is
          therefore reported as a warning unless it is listed here. The value
          passes through unchanged in either case:

          ```nix
          ai.claude.native.settings.someBrandNewKey = true;
          ai.claude.allowUnrecognizedSettings = ["someBrandNewKey"];
          ```

          ${openKeys.allowlistSyntax}

          This is a per-key opt-out that lasts until you delete it, not a home
          for the key. Once the sidecar catches up and the binary declares it,
          the entry is reported as a stale warning — left in place
          it would silently re-open the typo hole for that one key at the next
          upstream rename.

          Opaque leaf containers such as `env` accept arbitrary children. Maps
          accept arbitrary entry names while declared fields below each entry
          remain checked; lists inspect their declared element shape.
        '';
      };
      ultracodeOnLaunch = lib.mkEnableOption ''
        starting every Claude session in ultracode (standing dynamic-workflow
        orchestration at the session's effort level).

        Session-setup convenience, NOT the per-turn "ultracode" keyword
        (that is `settings.workflowKeywordTriggerEnabled`, orthogonal).
        When true, writes `settings.ultracode = true` and
        `settings.enableWorkflows = true` via mkDefault, so an explicit
        `ai.claude.native.settings.*` still wins. Does NOT set effortLevel —
        ultracode runs at the session's effort level. The
        `--effort ultracode` CLI flag also sets xhigh.

        On Opus 5 the heron_brook clamp negates ultracode unless a user-voiced
        grant is present; the delegate-routing per-turn reminder supplies it.'';
      marketplaces = lib.mkOption {
        type = with lib.types; attrsOf (either package path);
        default = {};
        description = ''
          Claude plugin marketplaces. Each entry is either a path to a
          marketplace directory or a package derivation. Written into
          `.claude/settings.json` as an `extraKnownMarketplaces` directory
          source on both backends, which Claude registers itself — at once
          from user settings, after the workspace trust dialog from a
          project's.
        '';
        example = lib.literalExpression ''
          {
            my-marketplace = ./my-marketplace;
          }
        '';
      };
      outputStyles = lib.mkOption {
        type = with lib.types; attrsOf (either lines path);
        default = {};
        description = ''
          Claude custom output styles. Attribute name becomes the style
          filename stem; value is inline markdown or a path to a .md
          file. Each lands at `.claude/output-styles/<name>.md` under the
          backend root.
        '';
        example = lib.literalExpression ''
          {
            concise = "Keep answers under 3 sentences.";
            tutorial = ./styles/tutorial.md;
          }
        '';
      };
      commands = lib.mkOption {
        type = with lib.types; attrsOf (either lines path);
        default = {};
        description = ''
          Claude custom slash-commands. Attribute name becomes the
          command filename stem; value is inline markdown or a path
          to a .md file. Each lands at `.claude/commands/<name>.md` under
          the backend root.
          Claude-only — Kiro and Copilot have no analogous command
          concept, so no top-level `ai.commands` fanout.
        '';
        example = lib.literalExpression ''
          {
            fix-issue = ./commands/fix-issue.md;
          }
        '';
      };
      hooks = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf hookMatcherBlock);
        default = {};
        description = ''
          Typed Claude hook event wiring, keyed by event name — mirrors
          settings.json `hooks.<Event>` 1:1. Each event maps to a list of
          matcher blocks; each block has an optional `matcher` and a list of
          typed handlers. Lowered into `.claude/settings.json` on both
          backends.

          The event key is a soft enum: the ${toString (builtins.length (claudeFact "hookEvents"))}
          recognized events (extracted from the packaged binary into the
          drift-checked packages/claude-code/extracted/, hookEvents — never hard-coded)
          are ${lib.concatStringsSep ", " (claudeFact "hookEvents")}. Any string is
          accepted (forward-compatible with newer binaries).

          For hooks that need supporting files, set a handler `command` to a
          package (e.g. writeShellApplication) — the script and its data files
          ride the /nix/store closure at absolute paths. Use
          `ai.claude.hookScripts` only for trivial inline single-file hooks.
          Claude-specific — portable command hooks for the shared
          Claude/Codex lifecycle intersection belong under `ai.hooks`. Kiro's
          `ai.kiro.hooks` takes JSON-shaped definitions.
        '';
        example = lib.literalExpression ''
          {
            PreToolUse = [
              {
                matcher = "Bash";
                hooks = [{command = pkgs.writeShellApplication { /* ... */ };}];
              }
            ];
          }
        '';
      };
      hookScripts = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = {};
        description = ''
          Inline Claude hook script bodies, materialized as executable files
          at `.claude/hooks/<name>` under the backend root. Attribute name =
          filename, value = script body. For trivial single-file hooks only — hooks that need supporting
          files should use a package `command` in `ai.claude.hooks` instead.
          Claude-only — Kiro's `ai.kiro.hooks` takes JSON-shaped definitions.
        '';
        example = lib.literalExpression ''
          { pre-edit = "#!/usr/bin/env bash\nexec :\n"; }
        '';
      };
      hookScriptsDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          Claude-specific directory of inline hook scripts. Each regular file
          becomes one entry in `ai.claude.hookScripts` keyed by the filename
          (no extension strip — Claude hooks are typically extensionless shell
          scripts). Accepts a path literal or `{ path, filter? }` (filter:
          name → bool, default accepts every regular file). Claude-only.
        '';
        example = lib.literalExpression ''./hooks'';
      };
      memoryCollisionGuard = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Pause the first write to each agent-memory file per session and hand the
                model the directory's recently-modified neighbours first. Off by default.

                Concurrent Claude Code sessions share one memory directory and neither
                sees the other's writes — no locking, no notification. A session reads
                the memory index once at start and then writes into a directory that may
                have moved underneath it. Two sessions on 2026-08-05 recorded the same
                concept under different filenames minutes apart and agreed only by luck.
                The failure is silent: a duplicate under a different name raises no
                conflict, it just stops being findable, because the wikilink graph
                resolves by name.

                A `PreToolUse` hook on `Write|Edit` returns `permissionDecision: "deny"`
                with the neighbour listing as the reason, then allows the retry — one
                extra round trip per distinct file, once per session.

                OFF by default deliberately: this hook BLOCKS a tool call, and its
                cadence is an untuned gut call rather than a measured one. Opt in per
                consumer until there is evidence about whether it helps more than it
                interrupts.

                The alternative instrumentation — allow the write and inject the listing
                as `additionalContext`, reactive rather than blocking — is documented
                alongside this one in `packages/claude-code/lib/memory-collision-guard.sh`
                so a pivot does not have to re-derive the trade-off.
              '';
            };
            extraDirectories = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = ''
                Additional absolute directories to guard.

                By default the guard matches the PATTERN
                `<claude config dir>/projects/*/memory/*`, resolved at run time from
                `CLAUDE_CONFIG_DIR`. That is a pattern rather than a computed path on
                purpose: the memory directory is keyed by a slug of the session's cwd, so
                every worktree of one repository gets its own, and deriving the exact path
                would need the slug rule and would silently miss whenever it changed.

                Use this only for memory stores living outside that layout.
              '';
              example = lib.literalExpression ''["/srv/shared/agent-memory"]'';
            };
            listCount = lib.mkOption {
              type = lib.types.ints.positive;
              default = 10;
              description = ''
                How many recently-modified neighbours to list, most recent first. Each
                contributes its filename, mtime and `description:` frontmatter line — file
                bodies are never read, so this cannot spill memory contents into a hook
                payload.
              '';
            };
            windowMinutes = lib.mkOption {
              type = lib.types.ints.positive;
              default = 10;
              description = ''
                Minutes within which a neighbouring memory file's mtime is reported as a
                live concurrent session rather than as history. The signal this exists to
                surface is "another session is writing here RIGHT NOW", so this wants to
                be close to a session's working tempo, not to a retention period.
              '';
            };
          };
        };
        default = {};
        description = ''
          Guard against two concurrent sessions recording the same memory under
          different filenames. Off by default; see `enable`.
        '';
      };
    };
    # Describe each delivered surface once; a per-backend difference reads
    # `backend`.
    config = {
      backend,
      cfg,
      config,
      hasMergedContext,
      mergedAgents,
      mergedContext,
      mergedRules,
      mergedServers,
      mergedSkills,
      moduleEnvironmentVariables,
      options,
      resolvedSettings,
      resolvedShell,
      topHooks,
      ...
    }: let
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      isHm = backend == "hm";
      nativeSettings = aiCommon.filterNulls cfg.native.settings;
      # The typed event map (the one renderer Kimchi's hooks.json also uses)
      # and the legacy `native.settings.hooks` escape hatch, joined per event
      # HERE: a document's `content.value` merges leaf-wise, so two
      # contributions of one event's list would conflict rather than append.
      hooks =
        lib.zipAttrsWith (_: lib.concatLists)
        [(sharedHooks.render effectiveHooks) (nativeSettings.hooks or {})];
      # Every settings contribution reaches this one document through
      # `native.settings`, so a consumer's own key beats a generated default
      # by the ordinary option priorities.
      settingsDocument = removeAttrs nativeSettings ["hooks"] // lib.optionalAttrs (hooks != {}) {inherit hooks;};
      renderedServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
      personalPluginFiles = lib.filterAttrs (_: value: value != {}) {
        ".mcp.json" = lib.optionalAttrs (mergedServers != {}) {mcpServers = renderedServers;};
      };
      # Its manifest only when it carries something to load.
      personalPluginEntries = lib.optionalAttrs (personalPluginFiles != {}) (
        lib.mapAttrs' (file: value:
          lib.nameValuePair ".claude/skills/${personalPlugin}/${file}" (staged (
            if file == ".mcp.json"
            then "mcpServers"
            else "settings"
          ) "json" {inherit value;})) (personalPluginFiles // {".claude-plugin/plugin.json" = {name = personalPluginManifest;};})
      );
      marketplaceEntry = source: {
        source = {
          source = "directory";
          path = "${source}";
        };
      };
      pluginCollisions = lib.intersectLists (lib.attrNames cfg.plugins) ([personalPlugin] ++ lib.attrNames mergedSkills);
      # The backend's own Claude module writes the same files. Read through
      # `attrByPath`, so a configuration that never imported it evaluates.
      upstreamEnable =
        if isHm
        then ["programs" "claude-code" "enable"]
        else ["claude" "code" "enable"];
    in
      lib.mkMerge [
        (lib.optionalAttrs (options ? warnings) {
          warnings =
            nativeFileWarnings cfg
            # package = null is the config-only opt-out: no launcher can clear
            # the descriptor Claude caches before loading these settings.
            ++ lib.optional (cfg.package
              == null
              && claudeInference.launcherFlags {
                inherit backend;
                resolvedInference = resolvedSettings.inference;
              }
              != [])
            "ai.claude.settings.inference is selected but ai.claude.package is null; launch Claude with CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR unset, because only the managed launcher suppresses that inherited credential before startup."
            ++ lib.optional (!isHm && cfg.plugins != {})
            "ai.claude.plugins is set but ${backend} does not deliver it to claude (reason: The devenv backend has no writer for this Claude surface.)";
        })
        {
          assertions = [
            {
              assertion = !(lib.attrByPath upstreamEnable false config);
              message = "ai.claude.enable and ${lib.concatStringsSep "." upstreamEnable} cannot both be on: each writes Claude's files, and they cannot share them. Disable one of the two.";
            }
          ];
        }
        (lib.mkIf (resolvedSettings.reasoningEffort != null) {
          ai.claude.native.settings.effortLevel = lib.mkDefault resolvedSettings.reasoningEffort;
        })
        (shellSettings {inherit resolvedShell moduleEnvironmentVariables;})
        (claudeInference.config {
          inherit backend;
          resolvedInference = resolvedSettings.inference;
        })
        {assertions = claudeInference.assertions resolvedSettings.inference;}
        # L2b → L3: expand `ai.claude.hookScriptsDir` into
        # `ai.claude.hookScripts`. Content is `readFile`'d into
        # `lib.types.lines` via hooksFromDir.
        (lib.mkIf (cfg.hookScriptsDir != null) {
          ai.claude.hookScripts = lib.mapAttrs (_: lib.mkDefault) (
            lib.ai.hooksFromDir cfg.hookScriptsDir
          );
        })
        # Agent-memory collision guard (default OFF). An `ai.claude.hooks`
        # definition, so it list-merges onto PreToolUse with any consumer
        # entries instead of clobbering them.
        (lib.mkIf cfg.memoryCollisionGuard.enable {
          ai.claude.hooks = memoryCollisionGuardHooks cfg.memoryCollisionGuard;
        })
        # Meta option: ultracode on at every launch. Writes the
        # `ultracode` key plus the
        # `enableWorkflows` master toggle via mkDefault so an explicit
        # `ai.claude.native.settings.*` still wins. This is the single place the
        # `ultracode` key is written. No effortLevel — ultracode runs at the
        # session's effort level. No workflowKeywordTriggerEnabled — orthogonal per-turn key.
        (lib.mkIf cfg.ultracodeOnLaunch {
          ai.claude.native.settings = {
            ultracode = lib.mkDefault true;
            enableWorkflows = lib.mkDefault true;
          };
        })
        {
          ai.claude.native.settings.permissions = lib.mkMerge (lib.mapAttrsToList (mode: rows:
            lib.mkIf (rows != []) {${claudeToolRules.${mode}} = map (claudeToolName isHm) rows;})
          (aiCommon.mcpToolPolicy mergedServers));
        }
        # Settings are configuration, so Nix owns the whole file and links it
        # read-only on both backends: an in-app change such as `/tui` does not
        # persist, by design. `$schema` gives editors validation and completion
        # of that file; it rides outside `native.settings` so the
        # unrecognized-key guard never sees it, and it is added only to a
        # non-empty document so it never makes an empty declaration write one.
        (lib.mkIf (settingsDocument != {}) {
          ai.claude._generatedFiles.".claude/settings.json" = staged "settings" "json" {
            value = {"$schema" = "https://json.schemastore.org/claude-code-settings.json";} // settingsDocument;
          };
        })
        # Claude registers a marketplace it does not know from
        # `extraKnownMarketplaces`: immediately from user settings, after the
        # workspace trust dialog from a project's. Its own registry,
        # known_marketplaces.json, is runtime state it writes itself.
        {
          ai.claude.native.settings.extraKnownMarketplaces =
            lib.mapAttrs (_: source: lib.mkDefault (marketplaceEntry source)) cfg.marketplaces;
        }
        (lib.mkIf hasMergedContext {
          ai.claude._generatedFiles.${contextPath cfg} = staged "context" "markdown" (aiTypes.textSourceFile mergedContext);
        })
        # Attrs-shape ai.rules / ai.claude.rules → .claude/rules/<name>.md.
        # Each entry becomes one file, translated through claudeTransformer
        # (paths: frontmatter).
        #
        # A project rule must be a real file: Claude's rules loader skips a
        # `.claude/rules/*.md` whose symlink target leaves the project, and its
        # scoped-rule (`paths:`) loader passes `includeExternal: false` at
        # Project scope with no setting to change it (claude-code 2.1.280).
        # User scope passes true, so Home Manager's `~/.claude/rules` links
        # load. Hence devenv copies read-only and HM links. The engine owns
        # each copy alone, so a hand-placed rule survives.
        {
          ai.claude._generatedFiles =
            lib.mapAttrs (_path: text:
              staged "rules" "markdown" {inherit text;}
              // {
                method = {
                  devenv = "ro";
                  hm = "symlink";
                };
              }) (aiCommon.renderRules {
              context = name: {package = name;};
              path = rulePath;
              rules = mergedRules;
              runtime = "claude";
              transformer = lib.ai.transformers.claude.claudeTransformer;
            })
            # Agents, commands and output styles: one Markdown link each.
            // markdownFiles "agents" mergedAgents
            // markdownFiles "commands" cfg.commands
            // markdownFiles "output-styles" cfg.outputStyles
            // lib.mapAttrs' (name: body:
              lib.nameValuePair ".claude/hooks/${name}" (staged "hooks" "raw" {text = body;} // {executable = true;}))
            cfg.hookScripts
            // helpers.mkSkillFiles {
              configDir = ".claude";
              skills = mergedSkills;
            };
        }

        (lib.optionalAttrs isHm (lib.mkMerge [
          {
            assertions = [
              {
                assertion = pluginCollisions == [];
                message = "ai.claude.plugins ${lib.concatStringsSep ", " pluginCollisions} would land at ~/.claude/skills/<name>, which ${lib.concatStringsSep " or " (lib.optional (lib.elem personalPlugin pluginCollisions) "the ${personalPlugin} personal plugin" ++ lib.optional (lib.intersectLists pluginCollisions (lib.attrNames mergedSkills) != []) "an ai.skills entry")} already owns. Rename the plugin key.";
              }
              # A skill of that name would share the plugin's directory, and
              # Claude would load the directory as the plugin, not the skill.
              {
                assertion = personalPluginEntries == {} || !(mergedSkills ? ${personalPlugin});
                message = "ai.skills.${personalPlugin} (or ai.claude.skills.${personalPlugin}) would land at ~/.claude/skills/${personalPlugin}, which the ${personalPlugin} personal plugin already owns. Rename the skill.";
              }
            ];
          }
          {
            ai.claude._generatedFiles =
              personalPluginEntries
              // lib.mapAttrs' (name: plugin:
                lib.nameValuePair ".claude/skills/${name}" {content.source = pluginLib.mkPluginEntry name plugin;})
              cfg.plugins;
          }
          {
            ai.claude = {
              _generatedFiles.".claude.json" = let
                value =
                  cfg.native.unpinLaunchEffort
                  // lib.optionalAttrs (cfg.native.installMethod != null) {inherit (cfg.native) installMethod;};
              in
                staged "settings" "json" {inherit value;}
                // {
                  enable = value != {};
                  method = lib.mkDefault "rw";
                };
              # Keep credential repair after the engine, even with no flags.
              activation.claude-config-mode = {
                after = ["materialized"];
                command = ''
                  credential_file="$HOME/.claude.json"
                  if [ -f "$credential_file" ] && [ ! -L "$credential_file" ]; then
                    ${pkgs.coreutils}/bin/chmod go-rwx -- "$credential_file"
                  fi'';
              };
            };
          }
        ]))
        # The project's .mcp.json, as read-only as its settings.json.
        (lib.optionalAttrs (!isHm) (lib.mkIf (mergedServers != {}) {
          ai.claude._generatedFiles.".mcp.json" = staged "mcpServers" "json" {value.mcpServers = renderedServers;};
        }))
      ];
    devenv.options.native.settings = nativeSettingsOption;
    # Home Manager only: devenv never writes HOME, so on devenv the option
    # does not exist and setting it is an unknown-option evaluation error.
    hm.options.native = {
      installMethod = lib.mkOption {
        # The values the packaged binary writes and compares (2.1.308).
        type = lib.types.nullOr (lib.types.enum ["development" "global" "local" "native" "unknown"]);
        default = "native";
        description = ''
          The `installMethod` key merged into ~/.claude.json. Claude compares
          it with the build it is running and warns on a mismatch;
          the packaged binary is the native build, so the default `"native"`
          silences "Running native installation but config install method
          is 'global'". `null` leaves the key to Claude, though a value this
          option wrote earlier is removed once. Home Manager only.
        '';
      };
      settings = nativeSettingsOption;
      unpinLaunchEffort = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = lib.genAttrs (claudeFact "launchEffortPins") (_: true);
        defaultText =
          lib.literalExpression
          ''lib.genAttrs (claudeFact "launchEffortPins") (_: true)'';
        description = ''
          Per-model "acknowledge launch-default effort" flags merged into
          ~/.claude.json so settings.effortLevel is honored instead of a
          newly-shipped model's launch-default effort pin. Keys are
          auto-derived from the packaged binary
          (packages/claude-code/extracted/, launchEffortPins). Set a key false
          to deliberately leave that model pinned. Home Manager only.
        '';
      };
    };
    hm.migrationConfig = _: {
      ai.claude.legacyLedgers = [
        {
          codec = "json";
          ledger = "json-settings/claude-unpin-launch-effort.json";
          path = ".claude.json";
        }
      ];
    };
    # The old devenv rules writer's ledger, declared while Claude is disabled
    # too, so the project copies it wrote drain on a disable as well as on
    # N→0. Home Manager linked its rules.
    devenv.migrationConfig = _: {
      ai.claude.legacyLedgers = [
        {
          codec = "dir";
          ledger = "materialize/claude-rules.manifest";
          path = ".claude/rules";
        }
      ];
    };
    contentTargets = {
      cfg,
      mergedRules,
      ...
    }: {
      context = contextPath cfg;
      rules = lib.mapAttrs (name: _: rulePath name) mergedRules;
    };
  }
