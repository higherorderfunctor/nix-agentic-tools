# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout (skills, mcpServers, instructions files) absorbed in
# Task 3 (A2).
{
  lib,
  pkgs,
  ...
}: let
  agent = import ../../../lib/ai/agent.nix {inherit lib;};
  sharedHooks = import ../../../lib/ai/hooks.nix {inherit lib;};
  # Eval-pure reads of COMMITTED source JSON (no IFD). See overlays.md
  # § IFD Patterns and memory project_claude_effort_pin_state.
  extracted =
    builtins.fromJSON (builtins.readFile ../../../overlays/claude-code-extracted.json);
  knownClaudeModels = extracted.models;

  # Typed hook wiring (northbound). S1: a handler `command` accepts a package,
  # coerced to its executable path so its supporting files ride the /nix/store
  # closure at absolute paths (Claude runs hooks with cwd = project root, so
  # relative companion paths are unsafe). A package with meta.mainProgram →
  # getExe; a bare-file derivation (writeShellScript/writeText) → its outPath; a
  # string passes through unchanged.
  pkgToCommand = sharedHooks.packageToCommand;
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
        type = lib.types.nullOr (lib.types.coercedTo lib.types.package pkgToCommand lib.types.str);
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
  # Shared lowering (both backends): typed event map → settings.json `hooks`
  # JSON. Per handler: `filterAttrs (v != null)` drops null command/timeout and
  # keeps `type` + the freeform tail (http url, prompt, …). Per block: omit a
  # null matcher (settings.json has no matcher for no-matcher events). Same-event
  # lists concat across module writers (formats.json merge), so this composes
  # with the legacy `settings.hooks` escape hatch and, on devenv, with the
  # git-hooks-run entry — never clobbers.
  hooksToSettings = hooksAttr:
    lib.mapAttrs (
      _event: blocks:
        map (
          block:
            (lib.optionalAttrs (block.matcher != null) {inherit (block) matcher;})
            // {hooks = map (h: lib.filterAttrs (_: v: v != null) h) block.hooks;}
        )
        blocks
    )
    hooksAttr;

  # heron_brook delegation clamp — the opt-in mitigation's hook pair.
  #
  # Two events, one script (./delegationClamp.nix):
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
  delegationClampHooks = clamp: let
    bin = lib.getExe (import ./delegationClamp.nix {
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
  # `env` is not a typed settings key — it rides the freeform JSON tail —
  # so this composes with a consumer's other `settings.env` entries rather
  # than replacing the attrset. mkDefault keeps an explicit
  # `ai.claude.settings.env.CLAUDE_CODE_SHELL` winning over the option.
  #
  # NOTE for anyone debugging a shell that did not take effect: Claude
  # SILENTLY falls back when the path is not executable — no warning, exit
  # 0, and it resolves its own bash instead. A package-typed option makes
  # that unreachable through this path, but a hand-written settings string
  # can still hit it.
  #
  # Identical on both backends because both write the same settings tree,
  # so it is defined once here rather than duplicated per callback.
  shellSettings = resolvedShell:
    lib.mkIf (resolvedShell != null) {
      ai.claude.settings.env.CLAUDE_CODE_SHELL =
        lib.mkDefault (lib.getExe resolvedShell);
    };
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "claude";
    # Honest: both backend callbacks consume `resolvedShell` via
    # `shellSettings` above. See mkAiApp.nix's record-shape note.
    supportsShell = true;
    transformers.markdown = lib.ai.transformers.claude;
    defaults = {
      package = pkgs.ai.claude-code;
    };
    # Shared options (present in both backends)
    options = {
      context = lib.mkOption {
        type = lib.types.either lib.types.lines lib.types.path;
        default = "";
        description = ''
          Global Claude context. Inline string or path to a file.
          Passed through to programs.claude-code.context (which writes
          to ~/.claude/CLAUDE.md). Replaces the deprecated upstream
          `memory.text` option.
        '';
        example = lib.literalExpression "./claude-memory.md";
      };
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
      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            attribution = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {
                  commit = lib.mkOption {
                    type =
                      lib.types.coercedTo lib.types.bool
                      (b:
                        if b
                        then null
                        else "")
                      (lib.types.nullOr lib.types.str);
                    default = null;
                    example = false;
                    description = ''
                      Attribution line Claude appends to commit messages
                      it authors (settings.json `attribution.commit`).
                      `true` (or null, the default) leaves Claude's own
                      default text ("Generated with Claude Code"); `false`
                      disables it (writes ""), dropping the generated /
                      co-author trailer; a string sets custom text. Coerced
                      to a nullOr-str at the type layer so it rides the
                      shared filterNulls lowering unchanged.
                    '';
                  };
                  pr = lib.mkOption {
                    type =
                      lib.types.coercedTo lib.types.bool
                      (b:
                        if b
                        then null
                        else "")
                      (lib.types.nullOr lib.types.str);
                    default = null;
                    example = false;
                    description = ''
                      Attribution footer Claude appends to pull-request
                      bodies (settings.json `attribution.pr`). Unlike
                      `commit`, Claude's own upstream default for `pr` is
                      already "" (pull-request attribution off), so here
                      `true`/null (keep Claude's default) and `false`
                      (write "" explicitly) coincide - both leave it
                      disabled; a string enables it with custom footer
                      text.
                    '';
                  };
                };
              };
              default = {};
              description = ''
                Commit / PR attribution (settings.json `attribution`).
                Each field accepts `true` (Claude's default), `false`
                (disabled - writes ""), or a literal string. Set
                `commit = false` to drop the co-author / "Generated with
                Claude Code" trailer.
              '';
            };
            effortLevel = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum extracted.effortLevels);
              default = null;
              description = ''
                Persisted Claude effort level. The valid set
                (low/medium/high/xhigh) is extracted from the packaged binary
                into overlays/claude-code-extracted.json. 'max' is session-only
                via /effort and cannot be persisted.
              '';
            };
            enableWorkflows = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = ''
                Master Workflows feature toggle — the /config "Dynamic
                workflows" setting. Enables the Workflow tool at all.
                null leaves Claude's own default (true). Mirrors a stable
                /config toggle; the key name is not in the official settings
                reference but has been stable across releases (verified on
                claude-code 2.1.202).
              '';
            };
            model = lib.mkOption {
              type =
                lib.types.nullOr
                (lib.types.either (lib.types.enum knownClaudeModels) lib.types.str);
              default = null;
              description = ''
                Claude model id. The ${toString (builtins.length knownClaudeModels)}
                non-retired ids in the packaged binary's model catalog
                (extracted into the drift-checked
                overlays/claude-code-extracted.json — never hand-curated) are
                ${lib.concatStringsSep ", " knownClaudeModels}. Any string is
                accepted (non-enforcing soft enum) — the binary's runtime model
                set is not a safe closed enum.
              '';
            };
            tui = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["default" "fullscreen"]);
              default = null;
              description = ''
                Terminal UI renderer — the persisted `/tui` setting.
                "fullscreen" is the flicker-free alt-screen renderer with
                virtualized scrollback (equivalent to env
                CLAUDE_CODE_NO_FLICKER=1); "default" is the classic
                main-screen renderer. null leaves Claude's own default.
                MUST be set here rather than via the interactive `/tui`
                command, which read-modify-writes settings.json and so fails
                against a read-only Nix store path. Verified on
                claude-code 2.1.206.
              '';
            };
            workflowKeywordTriggerEnabled = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = ''
                Whether the "ultracode" keyword in a prompt opts THAT TURN
                into the Workflow tool (per-turn) — the /config "Ultracode
                keyword trigger" row. Orthogonal to the ultracode session
                mode. null leaves Claude's own default (true). Mirrors a
                stable /config toggle; the key name is not in the official
                settings reference but has been stable across releases
                (verified on claude-code 2.1.202). NOTE: the persisted key is
                `workflowKeywordTriggerEnabled`, not `ultracodeKeywordTrigger`
                (that string is only an in-memory UI alias).
              '';
            };
          };
        };
        default = {};
        description = ''
          Typed Claude settings (attribution, effortLevel, enableWorkflows,
          model, tui, workflowKeywordTriggerEnabled) plus freeform passthrough,
          written to ~/.claude/settings.json by upstream. Null typed keys are
          filtered out before reaching upstream. The undocumented `ultracode`
          session key is intentionally NOT a typed option (see
          ultracodeOnLaunch) but remains reachable here via freeform
          passthrough.
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
          (overlays/claude-code-extracted.json). Set a key false to deliberately
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
        `ai.claude.settings.*` still wins. Does NOT set effortLevel —
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
      lspServers = lib.mkOption {
        type = lib.types.attrsOf (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule;
        default = {};
        description = ''
          Typed Claude-specific LSP server declarations. Merged with
          top-level `ai.lspServers`; per-CLI wins on name conflict.
          Translated via `mkClaudeLspConfig` to
          `programs.claude-code.lspServers`, which upstream writes into
          `~/.claude/settings.json`. Extensions list becomes
          `extensionToLanguage` mapping. Upstream devenv `claude.code`
          has no LSP surface — devenv ignores this option.
        '';
      };
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
      agents = lib.mkOption {
        type = lib.types.attrsOf agent.agentType;
        default = {};
        description = ''
          Claude-specific agent Markdown or portable semantic records (merged
          with top-level `ai.agents`; collisions fail). Routed to
          `programs.claude-code.agents`; upstream writes them under
          `~/.claude/agents/<name>.md`. HM only — upstream devenv
          `claude.code` has no agents surface.
        '';
      };
      agentsDir = lib.mkOption {
        type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
        default = null;
        description = ''
          Claude-specific directory of `.md` agent files. Each file
          becomes one entry in `ai.claude.agents` keyed by basename
          minus `.md`. Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default keeps
          `.md`).
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
      delegationClamp = lib.mkOption {
        type = lib.types.submodule {
          options = {
            mitigate = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Counteract Claude Code's `heron_brook` delegation clamp. Off by default.

                Claude Code injects a system-prompt section instructing the model not to
                call the Agent tool and not to use workflows or deep research "unless the
                user requested it". It is gated on a MODEL capability rather than on user
                configuration — on for Opus 5 — and there is no settings key, CLI flag, or
                environment variable that disables it. It never appears in the transcript,
                so a session with delegation silently suppressed looks identical to a
                normal one. It also directly negates `ai.claude.ultracodeOnLaunch`, which
                asks for the opposite.

                Rather than patch anything, this supplies the request the clamp's own
                escape clause is asking for: a `UserPromptSubmit` hook injects a standing
                request as USER-side context (see `text`).

                Injected once per session and re-armed by a `PreCompact` hook, since
                compaction is the one event that erases it — so the cost is roughly 75
                tokens per session, not per turn. Per-turn injection would be cumulative,
                because `additionalContext` is appended to the user message and persists
                in conversation history.

                Upstream issue: https://github.com/anthropics/claude-code/issues/80988.
                Set true to enable. A dated CI step re-surfaces this roughly every 90 days
                so the mitigation does not outlive its cause.
              '';
            };
            text = lib.mkOption {
              type = lib.types.lines;
              default = ''
                Standing request from me, the user: you have my permission to use subagents
                (the Agent/Task tool), workflows, and deep research whenever they fit the
                task at hand. Treat this as the request that any "unless the user requested
                it" condition is asking for — it is granted, now and for the rest of this
                session. Use your own judgment about when they actually fit; this grants
                permission, it does not oblige you to delegate.
              '';
              description = ''
                The standing request injected as user-side context.

                The default's phrasing is load-bearing, not incidental. It SATISFIES the
                clamp's "unless the user requested it" escape clause instead of
                contradicting the instruction — a contradiction pits a user-message line
                against a system-prompt line, which resolves toward the system prompt or
                toward hedging. It is affirmative rather than a negation of something the
                model cannot point at ("ignore any instruction telling you X" reads as
                adversarial injection and increases suspicion). It never presents itself
                as machine-generated or relayed, because an instruction understood to come
                from an automated parent gets discounted as not-a-user-request. And it
                GRANTS permission rather than mandating delegation, since an overreaching
                instruction invites that same discounting.

                Re-derive those four properties before rewording.
              '';
            };
          };
        };
        default = {};
        description = ''
          Mitigation for Claude Code's undocumented `heron_brook` delegation clamp,
          which suppresses subagent and workflow use on a model-capability gate with no
          user-facing off switch. On by default — see `mitigate` for what it is and why,
          and `packages/claude-code/docs/heron-brook-clamp.md` for the full account.
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
          drift-checked overlays/claude-code-extracted.json — never hard-coded)
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
        type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
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

                OFF by default deliberately, unlike `delegationClamp`. That one corrects
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
    # HM-specific projection
    hm = {
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedRules,
        mergedLspServers,
        mergedAgents,
        resolvedShell,
        topContext,
        topHooks,
        topSettings,
        ...
      }: let
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
        # Resolve effective context: per-CLI wins when set (non-empty);
        # else top-level `ai.context`; else empty (upstream default).
        effectiveContext =
          if cfg.context != ""
          then cfg.context
          else if topContext != null
          then topContext
          else "";

        # Compose the single always-on CLAUDE.md = context baseline + any
        # UNNAMED instructions, routed through upstream
        # `programs.claude-code.context` (the sole writer for this path — the
        # generic aggregate render was retired to end the double-writer
        # collision). Named instructions emit their own `.claude/rules/<name>.md`
        # below and are excluded from the composed context.
        unnamedInstructions = builtins.filter (i: !(i ? name)) mergedInstructions;
        composedContext = lib.ai.composeInstructionsFile {
          inherit effectiveContext unnamedInstructions;
          render = lib.ai.transformers.claude.render;
        };

        # Resolve rule body: path → readFile; string → passthrough.
        resolveRuleText = rule:
          if builtins.isPath rule.text
          then builtins.readFile rule.text
          else rule.text;
        dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      in
        lib.mkMerge [
          (lib.mkIf (topSettings.reasoningEffort != null) {
            ai.claude.settings.effortLevel = lib.mkDefault topSettings.reasoningEffort;
          })
          (shellSettings resolvedShell)
          # L2b → L3: expand `ai.claude.agentsDir` into per-CLI
          # `ai.claude.agents`. mkDefault lets explicit
          # `ai.claude.agents.<name>` entries win within this layer;
          # collisions with `ai.agents.<name>` still go through the
          # shared collision check in the transform.
          (lib.mkIf (cfg.agentsDir != null) {
            ai.claude.agents = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.agentsFromDir cfg.agentsDir
            );
          })
          # L2b → L3: expand `ai.claude.hookScriptsDir` into
          # `ai.claude.hookScripts`. Content is `readFile`'d into
          # `lib.types.lines` via hooksFromDir.
          (lib.mkIf (cfg.hookScriptsDir != null) {
            ai.claude.hookScripts = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.hooksFromDir cfg.hookScriptsDir
            );
          })
          # heron_brook delegation-clamp mitigation (default on). Writes into
          # `ai.claude.hooks` so it list-merges with any consumer entries on the
          # same two events rather than clobbering them. Paired with the identical
          # devenv-side write below — config parity is structural here, riding the
          # existing hooks fanout rather than adding a module axis.
          (lib.mkIf cfg.delegationClamp.mitigate {
            ai.claude.hooks = delegationClampHooks cfg.delegationClamp;
          })
          # Agent-memory collision guard (default OFF). Same `ai.claude.hooks`
          # definition write as the clamp, so it list-merges onto PreToolUse with
          # any consumer entries instead of clobbering them. Paired with the
          # identical devenv-side write below.
          (lib.mkIf cfg.memoryCollisionGuard.enable {
            ai.claude.hooks = memoryCollisionGuardHooks cfg.memoryCollisionGuard;
          })
          # Meta option: ultracode on at every launch. Writes the
          # (undocumented, officially session-only) `ultracode` key plus the
          # `enableWorkflows` master toggle via mkDefault so an explicit
          # `ai.claude.settings.*` still wins. This is the single place the
          # off-label `ultracode` key is written (its risk is disclosed in the
          # ultracodeOnLaunch description). No effortLevel — ultracode implies
          # xhigh. No workflowKeywordTriggerEnabled — orthogonal per-turn key.
          (lib.mkIf cfg.ultracodeOnLaunch {
            ai.claude.settings = {
              ultracode = lib.mkDefault true;
              enableWorkflows = lib.mkDefault true;
            };
          })
          # Typed event map → programs.claude-code.settings.hooks (shared helper;
          # HM has no typed hook backend to ride, so we generate the JSON). A
          # separate mkMerge entry so it composes with the freeform
          # `settings = filterNulls cfg.settings` write below — same-event lists
          # merge, so the legacy settings.hooks escape hatch and the typed map
          # coexist rather than clobber.
          (lib.mkIf (effectiveHooks != {}) {
            programs.claude-code.settings.hooks = hooksToSettings effectiveHooks;
          })
          # Delegate to upstream programs.claude-code.* where upstream
          # provides the capability. mkDefault lets consumers override.
          {
            programs.claude-code = {
              enable = lib.mkDefault true;
              package = lib.mkDefault cfg.package;
              skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
              context = lib.mkDefault composedContext;
              # Per-ENTRY mkDefault, like `skills` above — not a whole-attrset
              # one. `filterOverrides` keeps only the highest-priority
              # definitions of an option, so a single normal-priority
              # `programs.claude-code.plugins.<name>` from a consumer would
              # discard a whole-attrset mkDefault outright. Per-entry keeps the
              # other plugins and overrides just the named one.
              plugins = lib.mapAttrs (_: lib.mkDefault) cfg.plugins;
              inherit (cfg) marketplaces outputStyles commands;
              # Renamed script-bodies option → upstream script files. The typed
              # `ai.claude.hooks` event map lowers to settings.json separately
              # (the mkMerge entry above), NOT here.
              hooks = cfg.hookScripts;
              lspServers = lib.mapAttrs aiCommon.mkClaudeLspConfig mergedLspServers;
              agents = lib.mapAttrs agent.renderClaude mergedAgents;
              # Typed settings (effortLevel, model) plus freeform
              # passthrough. Null-filter the typed keys so upstream never
              # receives `effortLevel = null` / `model = null`; arbitrary
              # non-typed keys (permissions, env, outputStyle, …) pass
              # through the submodule's freeform JSON type unchanged.
              settings = aiCommon.filterNulls cfg.settings;
              # Render typed ai.mcpServers / ai.claude.mcpServers entries
              # into the freeform shape upstream's HM module expects.
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          }
          # Reconcile per-model launch-effort unpin flags into ~/.claude.json
          # so settings.effortLevel is honored instead of a newly-shipped
          # model's launch-default pin. HM-only — devenv never touches $HOME
          # (documented category exception). The log line is unconditional so
          # an emptied flag map is visible ("reconciling 0 …"); the merge body
          # is included only when there are flags. Never `exit` here — the
          # block inlines into HM's set -eu activation script. See memory
          # project_claude_effort_pin_state + feedback_hm_activation_exit.
          (let
            n = builtins.length (builtins.attrNames cfg.unpinLaunchEffort);
          in {
            home.activation.claudeUnpinLaunchEffort = lib.hm.dag.entryAfter ["linkGeneration"] (
              ''
                echo "ai.claude: reconciling ${toString n} launch-effort unpin flag(s) into ~/.claude.json"
              ''
              + lib.optionalString (n > 0) (helpers.mkSettingsActivationScript {
                configFile = ".claude.json";
                settingsJson = builtins.toJSON cfg.unpinLaunchEffort;
                jq = "${pkgs.jq}/bin/jq";
                inherit (pkgs) coreutils;
              })
            );
          })
          # Per-instruction rule files — write .claude/rules/<name>.md
          # for each instruction entry that carries a `name` field. This
          # is a gap in upstream programs.claude-code (no per-rule file
          # option), so we write home.file directly. Entries without a
          # `name` field are composed into `programs.claude-code.context`
          # (the single CLAUDE.md writer — see composedContext above).
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
            named = builtins.filter (i: i ? name) mergedInstructions;
          in {
            home.file = lib.listToAttrs (map (instr: {
                name = ".claude/rules/${instr.name}.md";
                value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
              })
              named);
          })
          # Attrs-shape ai.rules / ai.claude.rules → .claude/rules/<name>.md.
          # Each entry becomes one file, translated through claudeTransformer
          # (paths: frontmatter). Parallel emission to the legacy instructions
          # path above; name collisions between the two would raise a
          # home.file conflict at eval time (intentional — user fix).
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          in {
            home.file = lib.mapAttrs' (name: rule:
              lib.nameValuePair ".claude/rules/${name}.md" {
                text = fragmentsLib.mkRenderer claudeTransformer {package = name;} (rule
                  // {
                    text = resolveRuleText rule;
                  });
              })
            mergedRules;
          })
          # Auto-set ENABLE_LSP_TOOL=1 when MCP servers are present.
          # Mirrors the legacy modules/ai/default.nix behavior where
          # any populated server pool implied LSP-tool wiring.
          (lib.mkIf (mergedServers != {}) {
            programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
          })
        ];
    };
    # Devenv-specific projection
    devenv = {
      options = {};
      # `topContext` is the top-level `ai.context` fallback. devenv Claude has
      # no upstream context writer, so this projection composes context +
      # unnamed instructions into `files.".claude/CLAUDE.md"` itself — the sole
      # writer for that path. This also repairs the historical context-drop:
      # the retired aggregate render only wrote instructions and omitted context.
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedRules,
        resolvedShell,
        topContext,
        topHooks,
        topSettings,
        ...
      }: let
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
        dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
        resolveRuleText = rule:
          if builtins.isPath rule.text
          then builtins.readFile rule.text
          else rule.text;

        # Resolve effective context (per-CLI wins, else top-level) and compose
        # the single CLAUDE.md = context baseline + UNNAMED instructions. Named
        # instructions emit their own `.claude/rules/<name>.md` below.
        effectiveContext =
          if cfg.context != ""
          then cfg.context
          else if topContext != null
          then topContext
          else "";
        unnamedInstructions = builtins.filter (i: !(i ? name)) mergedInstructions;
        composedContext = lib.ai.composeInstructionsFile {
          inherit effectiveContext unnamedInstructions;
          render = lib.ai.transformers.claude.render;
        };
        hasComposedContext =
          (effectiveContext != null && effectiveContext != "")
          || unnamedInstructions != [];

        # Translate cfg.settings → backend surfaces.
        #
        # - `hooks` is handled separately (the dedicated legacy escape-hatch
        #   write below routes it to settings.json.hooks, composing with the
        #   typed event map) — so it is excluded from the generic gap write.
        # - `mcpServers` belongs in `.mcp.json`, not settings.json;
        #   filtered out defensively in case a user mis-assigns it
        #   (the authoritative path is the top-level ai.mcpServers pool).
        # - Everything else (effortLevel, permissions, env, outputStyle,
        #   …) is gap-written directly to `.claude/settings.json`.
        #
        # Pin settingsPath so our relative-key gap write and upstream's
        # own write hit the same `files.*` attr and the module system
        # deep-merges them into one settings.json. Upstream's default is
        # `${devenv.root}/.claude/settings.json` (absolute) which would
        # otherwise produce a separate files.* entry.
        separatelyHandledSettingsKeys = ["hooks" "mcpServers"];
        gapSettings =
          aiCommon.filterNulls
          (removeAttrs cfg.settings separatelyHandledSettingsKeys);
        hasGapSettings = gapSettings != {};
        effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      in
        lib.mkMerge [
          (lib.mkIf (topSettings.reasoningEffort != null) {
            ai.claude.settings.effortLevel = lib.mkDefault topSettings.reasoningEffort;
          })
          (shellSettings resolvedShell)
          # L2b → L3: expand `ai.claude.hookScriptsDir` into
          # `ai.claude.hookScripts` (parity with HM side). The devenv
          # factory merges `cfg.hookScripts` into `claude.code.hooks`
          # below, so this expansion flows through.
          (lib.mkIf (cfg.hookScriptsDir != null) {
            ai.claude.hookScripts = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.hooksFromDir cfg.hookScriptsDir
            );
          })
          # heron_brook delegation-clamp mitigation (parity with HM side). Same
          # `ai.claude.hooks` write, so the pair flows through the typed event map
          # → settings.json lowering below and concatenates with devenv's own
          # git-hooks-run entry instead of replacing it.
          (lib.mkIf cfg.delegationClamp.mitigate {
            ai.claude.hooks = delegationClampHooks cfg.delegationClamp;
          })
          # Agent-memory collision guard (parity with HM side). Same
          # `ai.claude.hooks` write, so it flows through the typed event map →
          # settings.json lowering below and concatenates with devenv's own
          # entries rather than replacing them.
          (lib.mkIf cfg.memoryCollisionGuard.enable {
            ai.claude.hooks = memoryCollisionGuardHooks cfg.memoryCollisionGuard;
          })
          # Meta option: ultracode on at every launch (parity with HM side).
          # Writes the (undocumented, officially session-only) `ultracode` key
          # plus the `enableWorkflows` master toggle via mkDefault so an
          # explicit `ai.claude.settings.*` still wins. Flows through the
          # gap-write below into .claude/settings.json. Risk disclosed in the
          # ultracodeOnLaunch description.
          (lib.mkIf cfg.ultracodeOnLaunch {
            ai.claude.settings = {
              ultracode = lib.mkDefault true;
              enableWorkflows = lib.mkDefault true;
            };
          })
          # Translate upstream-owned keys + pin the settings file path. Hooks are
          # NO LONGER fed to `claude.code.hooks` (that was the type-invalid
          # mis-feed — script bodies + a freeform event-map into devenv's
          # `attrsOf hookSubmodule`, masked by the module-eval stub). The typed
          # event map + the legacy escape hatch gap-write settings.json.hooks
          # below (concatenating with devenv's own git-hooks-run entry via the
          # formats.json list merge), and script bodies become greenfield files.
          {
            claude.code = {
              enable = lib.mkDefault true;
              # Render typed ai.mcpServers / ai.claude.mcpServers entries into
              # the freeform shape upstream's devenv module expects (parity
              # with the HM branch above). Upstream's server submodule has no
              # `package` option, so passing the raw typed entries through
              # fails its strict type ("option ... .package does not exist").
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
              settingsPath = lib.mkDefault ".claude/settings.json";
            };
          }
          # Typed event map → settings.json hooks (shared helper). devenv's
          # git-hooks-run and the legacy escape hatch concat into the same
          # per-event lists — no clobber, no per-event partition needed.
          (lib.mkIf (effectiveHooks != {}) {
            files.".claude/settings.json".json.hooks = hooksToSettings effectiveHooks;
          })
          # Legacy `settings.hooks` escape hatch → same settings.json.hooks,
          # verbatim (composes via the list merge, never clobbers).
          (lib.mkIf ((cfg.settings.hooks or {}) != {}) {
            files.".claude/settings.json".json.hooks = cfg.settings.hooks;
          })
          # Script bodies → standalone hook files (greenfield; mirrors HM's
          # programs.claude-code.hooks path, which devenv's claude.code lacks).
          (lib.mkIf (cfg.hookScripts != {}) {
            files =
              lib.mapAttrs'
              (name: body: lib.nameValuePair ".claude/hooks/${name}" {text = body;})
              cfg.hookScripts;
          })
          # Gap write — everything in cfg.settings that upstream doesn't
          # already handle. Uses `.json` format so module-system merges
          # our attrs with upstream's hook-only write into a single
          # settings.json on disk.
          (lib.mkIf hasGapSettings {
            files.".claude/settings.json".json = gapSettings;
          })
          # Compose CLAUDE.md — context baseline + UNNAMED instructions, the
          # single devenv writer for this path (the generic aggregate render
          # was retired). A path context with no unnamed instructions stays a
          # `source` symlink; otherwise it is inlined and concatenated.
          (lib.mkIf hasComposedContext {
            files.".claude/CLAUDE.md" =
              if builtins.isPath composedContext
              then {source = composedContext;}
              else {text = composedContext;};
          })
          # Gap writes — per-instruction rule files. devenv has no
          # per-rule option, so we write files.* directly. Entries
          # without a `name` field are composed into `.claude/CLAUDE.md`
          # above; named entries emit one rule file each here.
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
            named = builtins.filter (i: i ? name) mergedInstructions;
          in {
            files = lib.listToAttrs (map (instr: {
                name = ".claude/rules/${instr.name}.md";
                value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
              })
              named);
          })
          # Attrs-shape ai.rules / ai.claude.rules → .claude/rules/<name>.md.
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          in {
            files = lib.mapAttrs' (name: rule:
              lib.nameValuePair ".claude/rules/${name}.md" {
                text = fragmentsLib.mkRenderer claudeTransformer {package = name;} (rule
                  // {
                    text = resolveRuleText rule;
                  });
              })
            mergedRules;
          })
          # Skills — devenv has no upstream skills option on
          # claude.code (cachix/devenv#2441), so we write per-leaf
          # files.* entries via the mkDevenvSkillEntries walker. The
          # walker mirrors HM `recursive = true` in user space because
          # devenv `files.*.source` cannot recurse a directory itself.
          (let
            helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
          in {
            files = helpers.mkDevenvSkillEntries ".claude" mergedSkills;
          })
        ];
    };
  }
