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
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  sharedHooks = lib.ai.hooks;
  # Eval-pure reads of COMMITTED source JSON (no IFD). See overlays.md
  # § IFD Patterns and memory project_claude_effort_pin_state.
  extracted =
    builtins.fromJSON (builtins.readFile ../extracted.json);
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  unrecognizedSettings = import ./unrecognizedSettings.nix {inherit lib;};

  delegationClampMitigationDefaultProse = ''
    Standing request from me, the user: you have my permission to use subagents
    (the Agent/Task tool), workflows, and deep research whenever they fit the
    task at hand. Treat this as the request that any "unless the user requested
    it" condition is asking for — it is granted, now and for the rest of this
    session. Use your own judgment about when they actually fit; this grants
    permission, it does not oblige you to delegate.
  '';

  # The `native.settings` option surface: one option per path in the packaged
  # binary's own settings schema, merged with the hand-authored exceptions.
  # `.report` is what packages/claude-code/checks/claude-settings-schema.nix asserts on, so an
  # exception aimed at a key the binary no longer declares fails CI rather than
  # sitting here unnoticed.
  nativeFileSurface = import ./nativeOptions.nix {
    inherit extracted lib pkgs;
  };

  # Guard for the freeform `native.settings` tail: every key the packaged
  # binary's own extracted settings schema does not declare is a hard failure
  # unless `allowUnrecognizedSettings` names it. Claude ignores an unknown
  # settings key SILENTLY, so without this a misspelling looks applied and does
  # nothing.
  #
  # Consumed once by the shared config callback, which serves both backends —
  # the check is a property of the option, not of a backend, and the two
  # backends write the same settings tree. Same shape as mkKiro's `mkAssertions cfg`.
  #
  # `extracted.settings or null` degrades a sidecar that predates settings
  # extraction to "check off" rather than "eval throws" — but only while the
  # allowlist is empty; see the first assertion in unrecognizedSettings.nix.
  #
  # `cfg.package.version` is read ONLY inside message strings, so a passing
  # assertion never forces the package (and never triggers overlay IFD).
  nativeFileAssertions = cfg:
    unrecognizedSettings.mkAssertions {
      declared = extracted.settings or null;
      # The tree actually written — identical to the
      # `aiCommon.filterNulls cfg.native.settings` settings document below.
      # Filtering FIRST is load-bearing: a typed sub-option sitting at its
      # `null` default would otherwise report itself the day upstream renames
      # that key, for every consumer, including ones who never set it.
      settings = aiCommon.filterNulls cfg.native.settings;
      allowed = cfg.allowUnrecognizedSettings;
      optionPath = "ai.claude.native.settings";
      allowOptionPath = "ai.claude.allowUnrecognizedSettings";
      version = cfg.package.version or null;
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
        ultracode = ownWrite "ai.claude.ultracodeOnLaunch";
        mcpServers = "MCP servers do not belong in settings.json — declare them\n      under `ai.mcpServers` or `ai.claude.mcpServers`, which render into\n      the project .mcp.json (devenv) or the Home Manager personal plugin.";
      };
    };

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
  # heron_brook delegation clamp — the opt-in mitigation's hook pair.
  #
  # Two events, one script (./delegationClampMitigation.nix):
  #   UserPromptSubmit → inject the standing request ONCE per session. This event
  #                      specifically, because its additionalContext is appended to
  #                      the USER's message; a SessionStart injection renders
  #                      system-attributed and so cannot satisfy a clamp clause about
  #                      what the *user* requested.
  #   PreCompact       → clear the marker, because compaction is the one event that
  #                      erases the original injection.
  #
  # Emitted as a `ai.claude.hooks` DEFINITION rather than as that option's `default`:
  # an option default is discarded wholesale the moment a consumer defines the option
  # at all, whereas a definition list-merges with consumer entries on the same event.
  delegationClampMitigationHooks = clamp: let
    bin = lib.getExe (import ./delegationClampMitigation.nix {
      inherit lib pkgs;
      inherit (clamp) text;
    });
  in {
    PreCompact = [{hooks = [{command = "${bin} clear";}];}];
    UserPromptSubmit = [{hooks = [{command = "${bin} inject";}];}];
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
  # Emitted as an `ai.claude.hooks` DEFINITION for the same reason the clamp is: an
  # option default is discarded wholesale once a consumer defines the option at all,
  # whereas a definition list-merges with consumer entries on the same event.
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
  # Claude is the only harness here with no launcher wrapper, so its process
  # environment is expressed through `settings.env` in settings.json. Both the
  # typed shell and the module-contributed sandbox-safe SSH command ride it.
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

  # Devenv's project rules are ledger-owned copies (see the rules entries
  # below), which nothing but their writer retracts. Declared outside the
  # enable gate so the shell that DISABLES Claude still drains the copies the
  # previous one wrote: while disabled the adapter hands the writer no files,
  # so it only removes what the ledger recorded. Home Manager links its rules,
  # and its generation diff retracts them.
  rulesLedger = "materialize/claude-rules.manifest";
  # Where each unit lands, shared by the emitters below and `contentTargets`,
  # so the disabled-file warning names the path the emitter really wrote.
  contextPath = cfg: ".claude/${cfg.context.filename}";
  rulePath = name: ".claude/rules/${name}.md";
  rulesWriter = "materialize-claude-rules";
  claudeRulesWriterConfig = _: {
    ai.claude.activation.${rulesWriter} = {
      entry = "ai:claude:materialize-rules";
      ledgers.${rulesLedger} = {
        codec = "dir";
        path = ".claude/rules";
      };
      runWhenDisabled = true;
    };
  };
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  pluginLib = import ./plugin.nix {inherit lib pkgs;};

  # The Home Manager personal plugin that carries MCP and LSP servers — the
  # only route Claude has for user-scope LSP. Its directory name is ours; the
  # manifest name `hm` is the MCP tool namespace (`mcp__plugin_hm_<server>`),
  # kept short for token cost and stable for consumers that pin tool names.
  personalPlugin = "home-manager";
  personalPluginManifest = "hm";

  # Claude Markdown surfaces, one `.claude/<dir>/<name>.md` each. A path-like
  # value (path, store string, derivation) is linked as a `source`, anything
  # else is the file's text.
  markdownFiles = dir: values:
    lib.mapAttrs' (name: value: let
      content =
        if dir == "agents"
        then agent.renderFile true name value
        else agent.fileContent value;
    in
      lib.nameValuePair ".claude/${dir}/${name}.md" {
        content = lib.mkDefault ({
            enable = true;
          }
          // content);
        format = lib.mkDefault "markdown";
      })
    values;
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
    inherit pkgs;
    name = "claude";
    contextFilename = "CLAUDE.md";
    supportedPools = [
      "agents"
      "context"
      "hooks"
      "lspServers"
      "mcpServers"
      "rules"
      "settings"
      "shell"
      "skills"
    ];
    defaults = {
      package = pkgs.ai.claude-code;
    };
    # The builder declares these pool options; Claude states its delivery.
    poolOptions = {
      agents.description = ''
        Claude-specific agent Markdown or portable semantic records. Entries
        replace top-level `ai.agents` at the same key; null suppresses an
        inherited agent. Each lands at `.claude/agents/<name>.md` under the
        backend root (`~` for Home Manager, the project for devenv).
      '';
      agentsDir.description = ''
        Claude-specific directory of `.md` agent files. Each file
        becomes one entry in `ai.claude.agents` keyed by basename
        minus `.md`. Accepts a path literal or
        `{ path, filter? }` (filter: name → bool, default keeps
        `.md`).
      '';
      lspServers.description = ''
        Typed Claude-specific LSP server declarations. Entries replace
        top-level `ai.lspServers` at the same key; null suppresses an
        inherited server. Translated via `mkClaudeLspConfig` into the Home
        Manager personal plugin's
        `~/.claude/skills/home-manager/.lsp.json`, since a plugin is
        Claude's only LSP route. Extensions list becomes
        `extensionToLanguage` mapping. devenv has no LSP delivery and warns
        when this option is non-empty.
      '';
    };
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
      native.settings = lib.mkOption {
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
          packages/claude-code/extracted.json) gets a typed option
          automatically; a short hand-authored list overrides the generated
          type where the schema is not the surface we want (`attribution.*`
          accepts a bool, `model` is a soft enum, `tui` carries a
          read-only-store caveat). Null typed keys are filtered out before
          the document is written, so an option left at its default writes
          nothing.

          The freeform catch-all still accepts a key newer than this
          package's schema — see `allowUnrecognizedSettings`, which is what
          stops it accepting typos too. The undocumented `ultracode` session
          key is intentionally NOT a hand-authored option (see
          ultracodeOnLaunch) but is declared by the binary and so is typed
          like any other.
        '';
      };
      allowUnrecognizedSettings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["someBrandNewKey"];
        description = ''
          Dotted paths under `native.settings` that may be written even though
          the packaged claude-code binary does not declare them.

          The freeform tail of `native.settings` exists so a key upstream ships
          today is settable today. Its cost is that a TYPO is shaped exactly
          like a brand-new key — and Claude ignores an unknown settings key
          silently, so a misspelling looks applied and does nothing. Every key
          the binary's own extracted schema
          (packages/claude-code/extracted.json) does not declare is therefore a
          HARD FAILURE unless it is listed here:

          ```nix
          ai.claude.native.settings.someBrandNewKey = true;
          ai.claude.allowUnrecognizedSettings = ["someBrandNewKey"];
          ```

          An entry is a full dotted path, so a nested key works too
          (`"permissions.somethingNew"`). A `*` segment stands in for a key you
          chose yourself, so one entry covers every instance
          (`"modelPricing.overrides.*.newField"`).

          This is a per-key opt-out that lasts until you delete it, not a home
          for the key. Once the sidecar catches up and the binary declares it,
          the entry is REPORTED AS AN ERROR rather than ignored — left in place
          it would silently re-open the typo hole for that one key at the next
          upstream rename.

          Keys under a container the binary declares freeform — `hooks`, `env`,
          `skillOverrides`, `enabledPlugins`, `pluginConfigs`, `modelOverrides`,
          `vimInsertModeRemaps` and the rest — are never checked, so they never
          need an entry.
        '';
      };
      unpinLaunchEffort = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = lib.genAttrs extracted.launchEffortPins (_: true);
        defaultText =
          lib.literalExpression
          "lib.genAttrs extracted.launchEffortPins (_: true)";
        description = ''
          Per-model "acknowledge launch-default effort" flags merged into
          ~/.claude.json (HM only) so settings.effortLevel is honored instead of
          a newly-shipped model's launch-default effort pin. Keys are
          auto-derived from the packaged binary
          (packages/claude-code/extracted.json). Set a key false to deliberately
          leave that model pinned.
        '';
      };
      ultracodeOnLaunch = lib.mkEnableOption ''
          starting every Claude session in ultracode (xhigh effort plus
          standing dynamic-workflow orchestration).

          Session-setup convenience, NOT the per-turn "ultracode" keyword
          (that is `settings.workflowKeywordTriggerEnabled`, orthogonal).
          When true, writes `settings.ultracode = true` (⚠ see caveat) and
          `settings.enableWorkflows = true` via mkDefault, so an explicit
          `ai.claude.native.settings.*` still wins. Does NOT set effortLevel —
          ultracode implies xhigh unconditionally.

          ⚠ CAVEAT: the `ultracode` settings key is UNDOCUMENTED and
          officially session-only. Anthropic's docs describe ultracode as
          lasting only for the current session; only `disableWorkflows`
          appears in the official settings reference. Persisting
          `ultracode = true` relies on internal behavior (the binary reads it
          from any settings.json source) that works today (verified on
          claude-code 2.1.202) but carries no compatibility promise — a future
          release could stop honoring it without it counting as a breaking
          change. The claude-code overlay's extraExtract guard asserts the key
          still parses on each bump so a silent drop fails the update pipeline
        loudly'';
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
      delegationClampMitigation = lib.mkOption {
        type = aiTypes.optionalTextSource {
          defaultContent.text = delegationClampMitigationDefaultProse;
          description = "the standing request injected as user-side context";
          enableDefault = false;
        };
        default = {};
        defaultText = lib.literalExpression (lib.generators.toPretty {} {
          enable = false;
          text = delegationClampMitigationDefaultProse;
        });
        description = ''
          Counteract Claude Code's undocumented `heron_brook` delegation clamp. Enabling
          the mitigation installs both hooks with the selected prose; its packaged prose
          remains available while disabled.

          Claude Code injects a system-prompt section instructing the model not to call
          the Agent tool and not to use workflows or deep research "unless the user
          requested it". It is gated on a MODEL capability rather than on user
          configuration — on for Opus 5 — and there is no settings key, CLI flag, or
          environment variable that disables it. It never appears in the transcript, so
          a session with delegation silently suppressed looks identical to a normal one.
          It also directly negates `ai.claude.ultracodeOnLaunch`, which asks for the
          opposite.

          Rather than patch anything, this supplies the request the clamp's own escape
          clause is asking for: a `UserPromptSubmit` hook injects a standing request as
          USER-side context.

          Injected once per session and re-armed by a `PreCompact` hook, since compaction
          is the one event that erases it — so the cost is roughly 75 tokens per session,
          not per turn. Per-turn injection would be cumulative, because
          `additionalContext` is appended to the user message and persists in conversation
          history.

          The default's phrasing is load-bearing, not incidental. It SATISFIES the clamp's
          "unless the user requested it" escape clause instead of contradicting the
          instruction — a contradiction pits a user-message line against a system-prompt
          line, which resolves toward the system prompt or toward hedging. It is
          affirmative rather than a negation of something the model cannot point at
          ("ignore any instruction telling you X" reads as adversarial injection and
          increases suspicion). It is FIRST-PERSON, because live verification showed that
          this is what carries the weight even though the hook channel is visible. And it
          GRANTS permission rather than mandating delegation, since an overreaching
          instruction invites that same discounting.

          Re-derive those four properties before rewording.

          Upstream issue: https://github.com/anthropics/claude-code/issues/80988. A dated
          CI step re-surfaces this roughly every 90 days so the mitigation does not outlive
          its cause. See `packages/claude-code/docs/heron-brook-clamp.md` for the full
          account.
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

          The event key is a soft enum: the ${toString (builtins.length extracted.hookEvents)}
          recognized events (extracted from the packaged binary into the
          drift-checked packages/claude-code/extracted.json — never hard-coded)
          are ${lib.concatStringsSep ", " extracted.hookEvents}. Any string is
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

                OFF by default deliberately, unlike `delegationClampMitigation`. That one corrects
                a vendor defect and is strictly additive; this one BLOCKS a tool call,
                and its cadence is an untuned gut call rather than a measured one. Opt in
                per consumer until there is evidence about whether it helps more than it
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
      mergedLspServers,
      mergedRules,
      mergedServers,
      mergedSkills,
      moduleEnvironmentVariables,
      resolvedSettings,
      resolvedShell,
      topHooks,
      ...
    }: let
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      isHm = backend == "hm";
      # Claude's own state file, holding account tokens beside the unpin flags.
      claudeJson = ".claude.json";
      unpinLedger = "json-settings/claude-unpin-launch-effort.json";
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
        ".lsp.json" = lib.mapAttrs aiCommon.mkClaudeLspConfig mergedLspServers;
      };
      # Its manifest only when it carries something to load.
      personalPluginEntries = lib.optionalAttrs (personalPluginFiles != {}) (
        lib.mapAttrs' (file: value:
          lib.nameValuePair ".claude/skills/${personalPlugin}/${file}" {
            content.value = value;
            format = "json";
          }) (personalPluginFiles // {".claude-plugin/plugin.json" = {name = personalPluginManifest;};})
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
        # Unrecognized-key guard for the freeform native.settings tail. One
        # builder, both backends — see nativeFileAssertions.
        {assertions = nativeFileAssertions cfg;}
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
        # L2b → L3: expand `ai.claude.hookScriptsDir` into
        # `ai.claude.hookScripts`. Content is `readFile`'d into
        # `lib.types.lines` via hooksFromDir.
        (lib.mkIf (cfg.hookScriptsDir != null) {
          ai.claude.hookScripts = lib.mapAttrs (_: lib.mkDefault) (
            lib.ai.hooksFromDir cfg.hookScriptsDir
          );
        })
        # heron_brook delegation-clamp mitigation (default off). Writes into
        # `ai.claude.hooks` so it list-merges with any consumer entries on the
        # same two events rather than clobbering them on either backend.
        (lib.mkIf cfg.delegationClampMitigation.enable {
          ai.claude.hooks = delegationClampMitigationHooks cfg.delegationClampMitigation;
        })
        # Agent-memory collision guard (default OFF). Same `ai.claude.hooks`
        # definition write as the clamp, so it list-merges onto PreToolUse with
        # any consumer entries instead of clobbering them.
        (lib.mkIf cfg.memoryCollisionGuard.enable {
          ai.claude.hooks = memoryCollisionGuardHooks cfg.memoryCollisionGuard;
        })
        # Meta option: ultracode on at every launch. Writes the
        # (undocumented, officially session-only) `ultracode` key plus the
        # `enableWorkflows` master toggle via mkDefault so an explicit
        # `ai.claude.native.settings.*` still wins. This is the single place the
        # off-label `ultracode` key is written (its risk is disclosed in the
        # ultracodeOnLaunch description). No effortLevel — ultracode implies
        # xhigh. No workflowKeywordTriggerEnabled — orthogonal per-turn key.
        (lib.mkIf cfg.ultracodeOnLaunch {
          ai.claude.native.settings = {
            ultracode = lib.mkDefault true;
            enableWorkflows = lib.mkDefault true;
          };
        })
        # Settings are configuration, so Nix owns the whole file and links it
        # read-only on both backends: an in-app change such as `/tui` does not
        # persist, by design. `$schema` gives editors validation and completion
        # of that file; it rides outside `native.settings` so the
        # unrecognized-key guard never sees it, and it is added only to a
        # non-empty document so it never makes an empty declaration write one.
        (lib.mkIf (settingsDocument != {}) {
          ai.claude.files.".claude/settings.json" = {
            content.value = {"$schema" = "https://json.schemastore.org/claude-code-settings.json";} // settingsDocument;
            format = "json";
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
          ai.claude.files.${contextPath cfg} =
            aiCommon.contentFileEntry mergedContext;
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
        # load. Hence the per-backend fact: devenv copies read-only, HM links.
        # The directory ledger claims individual files, so a hand-placed rule
        # survives. Its writer is `claudeRulesWriterConfig`, declared whether
        # or not a rule is and whether or not Claude is enabled, so both N→0
        # and a disable retract the copies.
        {
          ai.claude.files = aiCommon.mkRuleFiles {
            context = name: {package = name;};
            fields = {
              entry = rulesWriter;
              facts.symlinkReadable = {
                devenv = false;
                hm = true;
              };
              ledger = rulesLedger;
            };
            path = rulePath;
            rules = mergedRules;
            runtime = "claude";
            transformer = lib.ai.transformers.claude.claudeTransformer;
          };
        }
        # Agents, commands and output styles: one Markdown link each.
        {ai.claude.files = markdownFiles "agents" mergedAgents;}
        {ai.claude.files = markdownFiles "commands" cfg.commands;}
        {ai.claude.files = markdownFiles "output-styles" cfg.outputStyles;}
        {
          ai.claude.files = lib.mapAttrs' (name: body:
            lib.nameValuePair ".claude/hooks/${name}" {
              content = lib.mkDefault {text = body;};
              executable = true;
            })
          cfg.hookScripts;
        }
        {
          ai.claude.files = helpers.mkSkillFiles {
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
          {ai.claude.files = personalPluginEntries;}
          {
            ai.claude.files = lib.mapAttrs' (name: plugin:
              lib.nameValuePair ".claude/skills/${name}" {
                content.source = pluginLib.mkPluginEntry name plugin;
                executable = null;
              })
            cfg.plugins;
          }
          # The flag gates Claude's LSP tool, which reads the personal
          # plugin's `.lsp.json`, so it follows the LSP servers, not MCP ones.
          (lib.mkIf (mergedLspServers != {}) {
            ai.claude.native.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
          })
          # Claude writes native state (including OAuth tokens) here. Own
          # only the unpin leaves. This user-global operation never runs from
          # a project shell.
          (helpers.mkReconciledDocument {
            content.value = cfg.unpinLaunchEffort;
            format = "json";
            ledger = unpinLedger;
            path = claudeJson;
            runtime = "claude";
            writer = "claudeUnpinLaunchEffort";
          })
          {
            # The unpin writer keeps an existing file's mode whether or not it
            # rewrites it, so this is the only thing that narrows a file an
            # earlier generation widened to 0644, with or without flags.
            ai.claude.activation.claudeConfigMode = helpers.mkCredentialModeWriter {
              inherit (pkgs) coreutils;
              path = claudeJson;
            };
          }
        ]))
        # The project's .mcp.json, as read-only as its settings.json.
        (lib.optionalAttrs (!isHm) (lib.mkIf (mergedServers != {}) {
          ai.claude.files.".mcp.json" = {
            content.value.mcpServers = renderedServers;
            format = "json";
          };
        }))
      ];
    devenv.migrationConfig = claudeRulesWriterConfig;
    contentTargets = {
      cfg,
      mergedRules,
      ...
    }: {
      context = contextPath cfg;
      rules = lib.mapAttrs (name: _: rulePath name) mergedRules;
    };
  }
