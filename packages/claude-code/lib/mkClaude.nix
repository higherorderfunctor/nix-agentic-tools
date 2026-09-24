# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout (skills, mcpServers, and rule files) absorbed in
# Task 3 (A2).
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
  # Built once and consumed by BOTH projections' mkMerge lists — the check is a
  # property of the option, not of a backend, and the two backends write the
  # same settings tree. Same shape as mkKiro's `mkAssertions cfg`.
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
      # The tree actually written — identical to the HM
      # `settings = aiCommon.filterNulls cfg.native.settings` write below.
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
        mcpServers = "MCP servers do not belong in settings.json — declare them\n      under `ai.mcpServers` or `ai.claude.mcpServers`, which render into\n      .mcp.json. The devenv projection already drops this key from its gap\n      write; the HM projection hands it to upstream verbatim.";
      };
    };

  # A single handler. `command` is modelled fully; the exotic handler types
  # (http/prompt/agent/mcp_tool) round-trip via the freeform JSON tail (and, on
  # devenv, force the gap-write path — see plan §9b).
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
        description = ''
          Per-handler timeout in seconds. Lowered into settings.json; on the
          devenv backend a non-null timeout forces the event onto the gap-write
          path (devenv's `claude.code.hooks` has no timeout field).
        '';
      };
    };
  };
  # One matcher block within an event: an optional matcher + its handlers.
  hookMatcherBlock = lib.types.submodule {
    options = {
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tool-name matcher (exact name or JS regex). Null for events that take no matcher (Stop, UserPromptSubmit, …).";
      };
      hooks = lib.mkOption {
        type = lib.types.listOf hookHandler;
        default = [];
        description = "Handlers that fire for this matcher block.";
      };
    };
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
  # environment is expressed through `settings.env` — which upstream writes
  # into settings.json. Both the typed shell and the module-contributed
  # sandbox-safe SSH command ride it.
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
        inherited agent. Home Manager routes them to
        `programs.claude-code.agents`, which writes
        `~/.claude/agents/<name>.md`; devenv writes project
        `.claude/agents/<name>.md` itself.
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
        inherited server. Translated via `mkClaudeLspConfig` to
        `programs.claude-code.lspServers`, which upstream writes into
        `~/.claude/settings.json`. Extensions list becomes
        `extensionToLanguage` mapping. Upstream devenv `claude.code`
        has no LSP surface — devenv warns when this option is non-empty.
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
          Routed to `programs.claude-code.plugins`.

          The ATTRIBUTE NAME is load-bearing: upstream uses it
          verbatim as the plugin's on-disk directory name
          (`<configDir>/skills/<name>` on Claude Code 2.1.157+; the
          derivation name and the synthesized
          `.claude-plugin/plugin.json` `name` field on every version),
          and its uniqueness — against other plugins and against
          `ai.skills` names — is asserted upstream.

          Attrset-only by design. Upstream still tolerates a plain list,
          but then derives each name from the entry's base name, so a
          bare flake-input store path yields an unstable
          `<hash>-source` that is renamed by every unrelated input bump.
          An explicit key pins the directory name across bumps. A list
          fails the type check here — convert it to an attrset.

          HM only — upstream devenv `claude.code` has no plugins surface,
          so devenv ignores this option.
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
          reaching upstream, so an option left at its default writes nothing.

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
          marketplace directory or a package derivation. Routed to
          programs.claude-code.marketplaces; upstream writes them into
          ~/.claude/settings.json under extraKnownMarketplaces.
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
          file. Routed to programs.claude-code.outputStyles; upstream
          writes them under ~/.claude/output-styles/<name>.md.
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
          to a .md file. Routed to `programs.claude-code.commands`;
          upstream writes them under `~/.claude/commands/<name>.md`.
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
          typed handlers. Lowered to settings.json on both backends
          (programs.claude-code.settings on HM; claude.code.hooks records plus
          a gap-write tail on devenv).

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
          Inline Claude hook script bodies, materialized as standalone files at
          `~/.claude/hooks/<name>` (HM: `programs.claude-code.hooks`; devenv:
          greenfield `files` write). Attribute name = filename, value = script
          body. For trivial single-file hooks only — hooks that need supporting
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
    # Describe each delivered surface once; only delegation to a backend's
    # native module remains backend-specific.
    config = {
      backend,
      cfg,
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
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      isHm = backend == "hm";
      # Claude's own state file, holding account tokens beside the unpin flags.
      claudeJson = ".claude.json";
      unpinLedger = "json-settings/claude-unpin-launch-effort.json";
      upstream = path: sink: value: {
        ai.claude.files.${path} = {
          content.value = value;
          method = "upstream";
          inherit sink;
        };
      };
      hmSurface = path: attribute:
        upstream path ["programs" "claude-code" attribute];
      # One entry composes all settings contributions before delegation. In
      # devenv the upstream integration also adds hooks to this same JSON sink;
      # handing it structured content preserves its list/deep-merge semantics.
      settings = value: {
        ai.claude.files.".claude/settings.json".content.value = value;
      };
      # MCP belongs in .mcp.json, never the project settings document. Hooks
      # keep their separate contribution so the legacy and typed maps append.
      gapSettings = aiCommon.filterNulls (removeAttrs cfg.native.settings ["hooks" "mcpServers"]);
    in
      lib.mkMerge [
        # Unrecognized-key guard for the freeform native.settings tail. One
        # builder, both backends — see nativeFileAssertions.
        {assertions = nativeFileAssertions cfg;}
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
        # Declare the sink once: list-valued sink paths concatenate if each
        # content contribution repeats them, producing a nested option path.
        (lib.mkIf (isHm || effectiveHooks != {} || gapSettings != {} || (cfg.native.settings.hooks != null && cfg.native.settings.hooks != {})) {
          ai.claude.files.".claude/settings.json" = {
            format = "json";
            method = "upstream";
            sink =
              if isHm
              then ["programs" "claude-code" "settings"]
              else ["files" ".claude/settings.json" "json"];
          };
        })
        # The one renderer Kimchi's hooks.json also uses. Same-event lists
        # concat across module writers (formats.json merge), so this composes
        # with the legacy `settings.hooks` escape hatch and, on devenv, with
        # the git-hooks-run entry — never clobbers.
        (lib.mkIf (effectiveHooks != {}) (settings {
          hooks = sharedHooks.render effectiveHooks;
        }))
        (lib.mkIf hasMergedContext {
          ai.claude.files.".claude/${cfg.context.filename}" =
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
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (lib.ai.transformers.claude) claudeTransformer;
        in {
          ai.claude.files = lib.mapAttrs' (name: rule:
            lib.nameValuePair ".claude/rules/${name}.md" {
              content = lib.mkDefault {
                enable = true;
                text = fragmentsLib.mkRenderer claudeTransformer {package = name;} (rule
                  // {
                    text = aiCommon.readContent rule;
                    paths = rule.matcher;
                  });
              };
              entry = rulesWriter;
              facts.symlinkReadable = {
                devenv = false;
                hm = true;
              };
              ledger = rulesLedger;
            })
          mergedRules;
        })

        (lib.optionalAttrs isHm (lib.mkMerge [
          # The upstream Home Manager module owns these surfaces, including
          # their plugin layout. Delivery records pass values to its options;
          # rendering them here would introduce a second writer.
          (hmSurface ".claude/agents" "agents" (lib.mapAttrs agent.renderClaude mergedAgents))
          (hmSurface ".claude/hooks" "hooks" cfg.hookScripts)
          (hmSurface ".claude/skills" "skills" (lib.mapAttrs (_: lib.mkDefault) mergedSkills))
          (hmSurface ".claude/skills/claude-code-home-manager/.lsp.json" "lspServers"
            (lib.mapAttrs aiCommon.mkClaudeLspConfig mergedLspServers))
          (hmSurface ".claude/skills/claude-code-home-manager/.mcp.json" "mcpServers"
            (lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers))
          (settings (aiCommon.filterNulls cfg.native.settings))
          (lib.mkIf (mergedServers != {}) (settings {
            env.ENABLE_LSP_TOOL = lib.mkDefault "1";
          }))
          {
            programs.claude-code = {
              enable = lib.mkDefault true;
              package = lib.mkDefault cfg.package;
              # Keep per-plugin defaults so overriding one upstream plugin
              # never discards the other generated entries.
              plugins = lib.mapAttrs (_: lib.mkDefault) cfg.plugins;
              inherit (cfg) commands marketplaces outputStyles;
            };
          }
          # Claude writes native state (including OAuth tokens) here. Own
          # only the unpin leaves and retain the writer when they are empty.
          # This user-global operation never runs from a project shell.
          {
            ai.claude.activation.claudeUnpinLaunchEffort.ledgers.${unpinLedger} = {
              codec = "json";
              path = claudeJson;
            };
            # The unpin writer keeps an existing file's mode whether or not it
            # rewrites it, so this is the only thing that narrows a file an
            # earlier generation widened to 0644, with or without flags.
            ai.claude.activation.claudeConfigMode = helpers.mkCredentialModeWriter {
              inherit (pkgs) coreutils;
              path = claudeJson;
            };
          }
          {
            ai.claude.files.${claudeJson} = {
              content.value = cfg.unpinLaunchEffort;
              entry = "claudeUnpinLaunchEffort";
              facts.harnessWrites = true;
              format = "json";
              ledger = unpinLedger;
            };
          }
        ]))
        (lib.optionalAttrs (!isHm) (lib.mkMerge [
          {
            claude.code = {
              enable = lib.mkDefault true;
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
              # Upstream defaults to an absolute key. Pin the relative key
              # so its hooks and our settings deep-merge into ONE file.
              settingsPath = lib.mkDefault ".claude/settings.json";
            };
          }
          # Test the value: hooks is a declared nullable option, so an
          # attribute fallback would still pass null to the JSON merge.
          (lib.mkIf (cfg.native.settings.hooks != null && cfg.native.settings.hooks != {})
            (settings {hooks = cfg.native.settings.hooks;}))
          (lib.mkIf (gapSettings != {}) (settings gapSettings))
          # Preserve the established project layout for script bodies and
          # skill leaves. These remain native symlink entries, with no shared
          # document for a writer to reconcile.
          {
            ai.claude.files = lib.mapAttrs' (name: body:
              lib.nameValuePair ".claude/hooks/${name}" {
                content = lib.mkDefault {text = body;};
                executable = null;
              })
            cfg.hookScripts;
          }
          # ai.agents / ai.claude.agents → .claude/agents/<name>.md, rendered by
          # the same renderer as HM's `programs.claude-code.agents`. Written
          # here rather than handed to upstream `claude.code.agents`: that
          # option requires typed description/prompt fields, so it cannot
          # carry a raw Markdown or path entry without parsing it.
          {
            ai.claude.files = lib.mapAttrs' (name: value: let
              rendered = agent.renderClaude name value;
            in
              lib.nameValuePair ".claude/agents/${name}.md" {
                content = lib.mkDefault (
                  {enable = true;}
                  // (
                    if agent.isPathLike rendered
                    then {source = rendered;}
                    else {text = rendered;}
                  )
                );
              })
            mergedAgents;
          }
          {
            ai.claude.files = helpers.mkSkillFiles {
              configDir = ".claude";
              skills = mergedSkills;
            };
          }
        ]))
      ];
    # Home Manager installs finalPackage through programs.claude-code. A
    # second profile entry would collide at bin/claude. Devenv's integration
    # has no package option, so it keeps the shared transform's installation.
    devenv.migrationConfig = claudeRulesWriterConfig;
    hm.installPackage = null;
  }
