# Copilot-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Copilot AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout absorbed in Task 4 (A3): settings.json activation merge,
# mcp-config.json static write, per-instruction rule files under the native
# project directory, and skills routing to that same project directory.
#
# Fanout absorbed in Task 4b (A3 gap-fill): lspServers typed LSP
# config write, environmentVariables fed into the symlinkJoin wrapper on both
# backends (devenv's `env` blob was retired 2026-08-10), agents + agentsDir
# option pair writing under `${configDir}/agents/`, and the HM
# symlinkJoin wrapper that injects `--additional-mcp-config` so the
# rendered mcp-config.json actually gets loaded by the copilot
# binary at runtime.
#
# ── PROVISIONAL: backend is standing in for PRODUCT ──────────────────
#
# "Copilot" is TWO products under one option namespace, and this module
# currently distinguishes them by BACKEND rather than by name:
#
#   Home Manager  → copilot-cli        reads `~/.copilot/…`
#   devenv        → github.com Copilot reads the repo's `.github/…`
#
# That mapping is true of how people happen to install each product, not
# of anything intrinsic, and it is exactly the conflation issue #920
# describes ("two runtimes under one name"). The intended fix is a real
# split into separate runtimes — `copilot-github` and `copilot` — which
# has NOT been designed yet; #920 stays open for it.
#
# So read the emission paths below, and the tests that pin them, as a
# PLACEHOLDER that happens to be right for the common case — not as an
# endorsement of backend-as-product. When the split lands, those paths
# move to the runtime that owns them and the assertions move with them.
#
# The github.com arm (devenv, `.github/instructions/`) is the one the
# maintainer actually consumes today; the CLI arm is fixed but unused.
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  # Carried as DATA, not a module argument — see mkAiApp.nix.
  inherit pkgs;
  name = "copilot";
  contextFilename = "copilot-instructions.md";
  supportedPools = [
    "agents"
    "context"
    "environmentVariables"
    "instructions"
    "lspServers"
    "mcpServers"
    "rules"
    "settings"
    "skills"
  ];
  transformers.markdown = lib.ai.transformers.copilot;
  defaults = {
    package = pkgs.ai.copilot-cli;
  };
  options = {
    # Keep the option visible in both backends even though only a project-local
    # devenv has a meaningful project root. Home Manager rejects non-default
    # overrides below instead of omitting the option: omission made the two
    # generated `ai.*` contracts drift and hid the scope distinction from HM
    # users. The shared default is also the native project layout consumed by
    # Copilot CLI and GitHub's cloud-side agents.
    projectDir = lib.mkOption {
      type = lib.types.str;
      default = ".github";
      description = ''
        Project-scope directory Copilot reads for context, rules, agents, and
        skills. Relative to the devenv root. Home Manager has no project root
        and rejects overrides; use a devenv declaration for project-local
        placement.
      '';
    };
    # Copilot-specific freeform settings. Consumed by the settings.json
    # activation merge in `hm.config` (runtime-merge via `jq -s '.[0] * .[1]'`
    # to preserve user-added `trusted_folders` across rebuilds) and by
    # the static write in `devenv.config`. Full typed surface (editor
    # integration, telemetry, typed model selection) is tracked in
    # docs/plan.md "Ideal architecture gate → Absorption backlog" under
    # the copilot-cli absorption item.
    nativeSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings merged into ~/.config/github-copilot/settings.json (HM: via activation script; devenv: via static write).";
    };
    # Typed LSP server definitions for lsp-config.json. Freeform
    # attrs-of-anything (matching the legacy `attrsOf jsonFormat.type`)
    # — consumers pass the JSON shape copilot expects. A richer typed
    # schema shared with kiro lives in `lib/ai-common.nix`
    # (`lspServerModule` + `mkCopilotLspConfig`) and is a pattern
    # expansion deferred until the cross-ecosystem `ai.lspServers`
    # surface lands; per-app options are fine for now.
    lspServers = lib.mkOption {
      type = lib.types.attrsOf (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule;
      default = {};
      description = "Typed LSP server definitions; translated via `mkCopilotLspConfig` into lsp-config.json on emission (adds fileExtensions mapping).";
    };
    # Baked into the symlinkJoin wrapper on BOTH backends. devenv used to
    # populate its native `env` attrset instead, which exported them into the
    # project shell rather than into Copilot. `attrsOf str` — matching the
    # legacy surface exactly.
    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables baked into the copilot launcher wrapper. Scoped to the Copilot process and the commands it spawns; never exported into the project shell.";
    };
    # Inline agent markdown content. Written under
    # `<configDir>/agents/<name>.md` in HM and
    # `<projectDir>/agents/<name>.agent.md` in devenv. Merged with
    # top-level `ai.agents`; collisions fail. Can also be populated
    # from a directory via `agentsDir` below (same L2b→L3 pattern as
    # `rulesDir` / `skillsDir`).
    agents = lib.mkOption {
      type = lib.types.attrsOf lib.ai.agent.agentType;
      default = {};
      description = "Agent Markdown or portable semantic records (HM: <configDir>/agents/<name>.md; devenv: <projectDir>/agents/<name>.agent.md).";
    };
    # Directory of `.md` agent files. Each file becomes one entry
    # in `ai.copilot.agents`, keyed by basename minus `.md`. Parity
    # with `rulesDir` / `skillsDir`: expansion runs through the
    # shared collision-as-failure check, and the on-disk emission
    # dir is NOT taken over wholesale (other derivations may still
    # contribute files alongside).
    agentsDir = lib.mkOption {
      type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
      default = null;
      description = "Directory of `.md` agent files (expanded into `ai.copilot.agents`).";
    };
  };
  hm = {
    options = {
      # Personal config dir relative to HOME. Default `.copilot`
      # matches Copilot CLI's canonical location (COPILOT_HOME).
      # Override if the CLI is configured to read elsewhere.
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".copilot";
        description = "Personal config dir relative to HOME (Copilot CLI's canonical location).";
      };
    };
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      mergedLspServers,
      mergedEnvironmentVariables,
      moduleEnvironmentVariables,
      mergedAgents,
      ...
    }: let
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      # Unnamed always-on instructions compose into the single native context
      # file below (the generic aggregate render was retired). Named entries
      # emit their own `<configDir>/instructions/<name>.instructions.md`.
      unnamedInstructions = builtins.filter (i: !(i ? name)) mergedInstructions;
      hasUnnamed = unnamedInstructions != [];
      # Complement of `unnamedInstructions`, hoisted so the `configDir`
      # assertion and the emission block below read the same set.
      namedInstructions = builtins.filter (i: i ? name) mergedInstructions;
      # symlinkJoin + makeWrapper wrapper that exports
      # `environmentVariables` and prepends `--additional-mcp-config
      # <path>` to every copilot invocation. Without this, the
      # `mcp-config.json` written below would sit on disk and never
      # be read — copilot only loads additional MCP config via the
      # explicit CLI flag. Conditional on there being something to
      # wrap; the raw `cfg.package` is used otherwise so consumers
      # with no env vars / no MCP servers don't pay for a rebuild.
      #
      # We use `wrapProgram` (from `makeWrapper`) rather than the
      # legacy inline bash heredoc. The legacy wrote `$out` into
      # the generated wrapper via a quoted `<< 'WRAPPER'` heredoc
      # and relied on `$out` being set at runtime, which it isn't
      # outside the nix build sandbox — that was a latent bug.
      # `wrapProgram` resolves the target path at wrap time
      # (substituting the real store path), which is the
      # conventional correct shape and matches the rest of the
      # ai-clis overlay.
      # The wrapper itself — including the `\''${HOME}` escaping and the `@`
      # file-path prefix, both of which shipped broken once — lives in
      # ./wrapPackage.nix and is shared with the devenv backend. Read that file
      # before changing anything here; the two details it guards are not
      # visible from the Nix side, and duplicating them is what let the same
      # pair of defects ship twice.
      #
      # HM passes `environmentVariables` through because symlinkJoin is its
      # only export mechanism. It therefore wraps when EITHER MCP servers or
      # env vars are configured; the helper decides that from its arguments, so
      # there is no `needsWrapper` to keep in sync here.
      copilotPackage = wrapCopilotPackage {
        inherit (cfg) package configDir;
        rootVar = "HOME";
        mcp = mergedServers != {};
        environmentVariables = moduleEnvironmentVariables // mergedEnvironmentVariables;
      };
      dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
      wrapCopilotPackage = import ./wrapPackage.nix {inherit lib pkgs;};
    in
      lib.mkMerge [
        # `projectDir` is shared for option-tree parity and discoverability, but
        # HM cannot give a project-relative path honest semantics. Keep the
        # native default inert and reject customization rather than silently
        # writing a HOME-relative directory that Copilot would interpret as a
        # different scope.
        {
          assertions = [
            {
              assertion = cfg.projectDir == ".github";
              message = ''
                ai.copilot.projectDir is project-local and cannot be changed
                through Home Manager. Configure it through the devenv module.
              '';
            }
            # THREE artifact classes here are discovered by Copilot walking its
            # own home rather than by being handed a path: named instructions,
            # rules, and the composed context file
            # (`<configDir>/<contextFilename>`, default
            # `copilot-instructions.md` — see the measured discovery list in
            # copilot-config-delivery.md). `mcp-config.json` survives a moved
            # `configDir` because the wrapper points `--additional-mcp-config`
            # straight at it; there is no instructions equivalent of that flag,
            # and this module deliberately does not set `COPILOT_HOME` (that
            # would fork auth and session state). So a non-default `configDir`
            # writes any of the three somewhere nothing reads, which is the
            # exact defect this path was just fixed for.
            #
            # The context file is easy to miss because it is emitted in a
            # different `mkMerge` branch (the `hasContext || hasUnnamed` one
            # below) from the instructions and rules writers. An earlier version
            # of this assertion covered only the first two and called them "the
            # only artifacts here", which left `ai.context` alone reproducing
            # the very defect being fixed.
            #
            # Gated on there being content to lose: a consumer using
            # `configDir` purely as the wrapper-aimed MCP root is unaffected,
            # and the failure arrives at the moment the first instruction, rule
            # or context line would go dead rather than at an unrelated config
            # change.
            #
            # This whole block rides `mkIf cfg.enable` (mkBackendTransform.nix
            # wraps `customConfig`), unlike the shared-pool collision
            # assertions, which sit outside it so bad SHARED data cannot hide
            # behind a disabled CLI. That is the right split: nothing is
            # emitted here while Copilot is off, so there is nothing to lose.
            {
              assertion =
                (namedInstructions == [] && !hasUnnamed)
                || cfg.configDir == ".copilot";
              message = ''
                ai.copilot.configDir is "${cfg.configDir}", but Copilot CLI
                discovers instructions, rules and its context file only under
                its own home (`~/.copilot/`). Home Manager cannot relocate that
                home, so these would be written and never read:

                ${lib.concatMapStringsSep "\n" (n: "  - ${n}") (
                  lib.sort (a: b: a < b) (
                    map (i: "${i.name}.instructions.md") namedInstructions
                    ++ lib.optional hasUnnamed cfg.context.filename
                  )
                )}

                Either leave ai.copilot.configDir at its ".copilot" default, or
                drop the ai.instructions entries above from this Home Manager
                configuration. Project-scope context and rules
                go through the devenv module, which writes them under
                ai.copilot.projectDir instead.
              '';
            }
          ];
        }
        # L2b → L3: expand `ai.copilot.agentsDir` into
        # `ai.copilot.agents`. mkDefault priority; collisions with
        # `ai.agents` go through the shared collision check.
        (lib.mkIf (cfg.agentsDir != null) {
          ai.copilot.agents = lib.mapAttrs (_: lib.mkDefault) (
            dirHelpers.agentsFromDir cfg.agentsDir
          );
        })
        # Package installation — wrapped with symlinkJoin when env
        # vars or MCP servers are configured so the binary picks up
        # `--additional-mcp-config` and the requested env. Matches
        # the legacy modules/copilot-cli/default.nix wrapper shape.
        {home.packages = [copilotPackage];}
        # agents + agentsDir are no longer mutually exclusive — the
        # Dir expansion feeds the same `ai.copilot.agents` pool via
        # mkDefault priority, so explicit entries override Dir
        # entries without a collision.
        # lsp-config.json — typed LSP server definitions for the
        # copilot CLI. Inlined via `text` so module-eval can assert
        # on content and we don't pay for a store build per eval.
        (lib.mkIf (mergedLspServers != {}) {
          home.file."${cfg.configDir}/lsp-config.json".text =
            builtins.toJSON (lib.mapAttrs aiCommon.mkCopilotLspConfig mergedLspServers);
        })
        # Inline agent .md files. Mirrors the legacy
        # `mkMarkdownEntries` shape — one entry per agent, written
        # under `${configDir}/agents/<name>.md`.
        (lib.mkIf (mergedAgents != {}) {
          home.file = lib.mapAttrs' (name: content:
            lib.nameValuePair "${cfg.configDir}/agents/${name}.md" {
              text = lib.ai.agent.renderCopilot name content;
            })
          mergedAgents;
        })
        # External agents directory handled at L2b→L3 above —
        # expansion runs through the existing per-file agents emission
        # instead of a wholesale Layout B symlink. Other derivations
        # may still contribute files to `${cfg.configDir}/agents/`.
        # mcp-config.json — static write of the merged MCP server
        # pool. The symlinkJoin wrapper above points
        # `--additional-mcp-config` at this exact path so copilot
        # loads these servers at runtime. Inlined as `text` so
        # module-eval can assert on content without a store build.
        (lib.mkIf (mergedServers != {}) {
          home.file."${cfg.configDir}/mcp-config.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Per-instruction files — write
        # `<configDir>/instructions/<name>.instructions.md` for each
        # instruction entry that carries a `name` field. The copilot
        # transformer emits `applyTo:` YAML frontmatter per scope.
        # Nameless entries are composed into the native context file
        # (`<configDir>/<contextFilename>`) below.
        #
        # This path used to be a hardcoded `.github/instructions/`, which
        # under Home Manager resolves to `$HOME/.github/instructions/` —
        # a directory copilot-cli never reads, so every named instruction
        # and every rule was written and then ignored. `.github` is the
        # PROJECT root that github.com's Copilot code review consumes; it
        # has no user-global meaning. See the devenv branch below, which
        # correctly prefixes `projectDir`, and
        # dev/fragments/ai-clis/copilot-config-delivery.md for the two
        # disjoint consumers this repo keeps confusing.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
        in {
          home.file = lib.listToAttrs (map (instr: {
              name = "${cfg.configDir}/instructions/${instr.name}.instructions.md";
              value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
            })
            namedInstructions);
        })
        # Legacy unnamed instructions retain their CLI-global file during the
        # additive transition. Normalized context and rules intentionally do
        # not emit on the Copilot HM arm: only the project-local product has a
        # consumed surface for them.
        (lib.mkIf hasUnnamed {
          home.file."${cfg.configDir}/${cfg.context.filename}" = let
            composed = lib.ai.composeInstructionsFile {
              effectiveContext = null;
              inherit unnamedInstructions;
              render = lib.ai.transformers.copilot.render;
            };
          in
            if builtins.isPath composed
            then {source = composed;}
            else {text = composed;};
        })
        # Skills fanout — copilot has no upstream HM skills option, so
        # we write `home.file."${configDir}/skills/<name>"` entries
        # directly via `mkSkillEntries`, which uses `recursive = true`
        # to produce Layout B (a real directory with per-file
        # symlinks) and is path-type-agnostic (accepts both Nix path
        # literals and absolute string paths).
        {
          home.file = helpers.mkSkillEntries cfg.configDir mergedSkills;
        }
        # Settings.json activation merge. Preserves user-added runtime
        # keys (e.g. `trusted_folders`) by merging Nix-declared values
        # on top of the existing file via `jq -s '.[0] * .[1]'`. On
        # first activation (no existing file) the Nix-rendered JSON is
        # written as-is. Ported from legacy
        # modules/copilot-cli/default.nix; the devenv side uses a plain
        # static write instead since devenv lifecycles are project-local.
        #
        # The settings JSON is inlined into the activation script via
        # `builtins.toJSON` so the rendered values (e.g. `model`,
        # `theme`) appear literally in the script text. This keeps the
        # activation atomic — no separate store-path read required at
        # runtime — and lets module-eval tests assert on the content.
        #
        # HM-only: gated on non-empty settings so consumers who enable
        # ai.copilot just for MCP/skills fanout don't clobber an
        # externally-managed settings.json. Matches upstream Claude HM
        # behavior. Devenv-side is unconditional (project-local).
        (lib.mkIf (cfg.nativeSettings != {}) {
          home.activation.copilotSettingsMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
            configFile = "${cfg.configDir}/settings.json";
            settingsJson = builtins.toJSON cfg.nativeSettings;
            jq = "${pkgs.jq}/bin/jq";
            inherit (pkgs) coreutils;
          });
        })
      ];
  };
  devenv = {
    options = {
      # Wrapper-aimed config dir. `mcp-config.json` here is LIVE — the
      # `packages` wrapper points `--additional-mcp-config` at it.
      # `lsp-config.json` and `settings.json` are INERT: Copilot reads
      # neither at project scope and offers no flag to inject them
      # (measured, see dev/fragments/ai-clis/copilot-config-delivery.md).
      # They are kept as declared-but-undelivered rather than removed, so
      # the option surface stays at HM parity and they become live for free
      # if upstream grows discovery. Project-scope files Copilot DOES read
      # live under `projectDir` (default `.github`) instead — that is also
      # the surface github.com's Copilot code review consumes, and it is a
      # different consumer from this CLI.
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/github-copilot";
        description = ''
          Wrapper-aimed config dir, relative to the devenv root. Holds
          `mcp-config.json`, which the wrapped `copilot` is pointed at via
          `--additional-mcp-config`.

          Also holds `lsp-config.json` and `settings.json`, which Copilot
          does NOT read at project scope and provides no flag to inject;
          those are written for option parity with Home Manager but are not
          delivered. Configure LSP servers and settings through the Home
          Manager module if they must take effect.

          This is NOT the directory github.com's Copilot code review reads —
          that consumes committed files under `projectDir` (`.github`), and
          this path is gitignored.
        '';
      };
    };
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      mergedRules,
      mergedLspServers,
      mergedEnvironmentVariables,
      moduleEnvironmentVariables,
      mergedAgents,
      mergedContext,
      ...
    }: let
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
      effectiveContext =
        if mergedContext == null
        then null
        else if (mergedContext.source or null) != null
        then mergedContext.source
        else mergedContext.text;
      hasContext = mergedContext != null;
      # Unnamed always-on instructions compose into the native context file
      # below (aggregate render retired); named entries emit their own files.
      unnamedInstructions = builtins.filter (i: !(i ? name)) mergedInstructions;
      hasUnnamed = unnamedInstructions != [];
      dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
      wrapCopilotPackage = import ./wrapPackage.nix {inherit lib pkgs;};

      # Wrapper that points copilot at the project's rendered mcp-config.json.
      # Only built when there is something to point at, so a project with no
      # MCP servers keeps the bare package and pays for no rebuild. See the
      # `packages` entry below for why this is required rather than optional,
      # and dev/fragments/ai-clis/copilot-config-delivery.md for the measured
      # discovery behavior and the rejected COPILOT_HOME alternative.
      #
      # `environmentVariables` IS passed, same as Home Manager. It used to be
      # withheld here because devenv exports through its native `env` attrset
      # — but that writes the PROJECT SHELL, so every variable also reached
      # the developer's interactive session and everything else running in it.
      # This module does not write the shell environment; devenv/Nix is the
      # config path, and process scope is the wrapper's job on both backends.
      # The helper still takes both inputs separately because MCP wrapping and
      # env wrapping are independently triggered.
      copilotPackage = wrapCopilotPackage {
        inherit (cfg) package configDir;
        rootVar = "DEVENV_ROOT";
        mcp = mergedServers != {};
        environmentVariables = moduleEnvironmentVariables // mergedEnvironmentVariables;
      };
    in
      lib.mkMerge [
        # L2b → L3: expand `ai.copilot.agentsDir` into
        # `ai.copilot.agents` (parity with HM side).
        (lib.mkIf (cfg.agentsDir != null) {
          ai.copilot.agents = lib.mapAttrs (_: lib.mkDefault) (
            dirHelpers.agentsFromDir cfg.agentsDir
          );
        })
        # Package installation. ENV wiring needs no wrapper — devenv has a
        # native `env` attrset (see the merge below). MCP config does, and
        # that is why `cfg.package` alone was NOT enough here.
        #
        # Copilot reads MCP config from exactly two places: `$HOME/.copilot/
        # mcp-config.json`, and whatever `--additional-mcp-config` points at.
        # It reads NOTHING from a project-local config dir. Measured by
        # syscall trace against 1.0.78: inside the project it touches only
        # `.github/copilot-instructions.md`, `.github/allowed_models.txt` and
        # `.git`, while `<project>/.config/github-copilot/{mcp,lsp}-config.json`
        # and `settings.json` are never opened or even stat'd.
        #
        # `configDir` was always "wrapper-aimed" (see its option comment);
        # devenv adopted it WITHOUT the wrapper, so the rendered
        # mcp-config.json sat on disk and nothing ever loaded it.
        #
        # `\''${DEVENV_ROOT}` is escaped so the launched shell expands it, not
        # the builder — the same hazard that shipped a `/homeless-shelter`
        # path on the HM side. `@` marks the value a FILE PATH; without it
        # copilot parses the path string as JSON and every session dies.
        {packages = [copilotPackage];}
        # agents + agentsDir are no longer mutually exclusive
        # (parity with HM side).
        # Environment variables ride `copilotPackage`'s wrapper above (see the
        # note there). The previous `env = …` write put them in the project
        # shell, which also handed them to the developer's own session; the
        # per-project escape hatch it enabled (`env.FOO = …`) is deliberately
        # gone, because devenv/Nix is the only config path here.
        # lsp-config.json — INERT at project scope. Copilot opens
        # `$HOME/.copilot/lsp-config.json` and nothing project-local, and
        # unlike MCP there is no `--additional-lsp-config` to point it here
        # (verified against 1.0.78 `--help`). Written anyway for option
        # parity with HM, and deliberately NOT an assertion: `ai.lspServers`
        # is a shared pool, so failing here would break a project that
        # legitimately targets Claude or Kiro with it.
        (lib.mkIf (mergedLspServers != {}) {
          files."${cfg.configDir}/lsp-config.json".text =
            builtins.toJSON (lib.mapAttrs aiCommon.mkCopilotLspConfig mergedLspServers);
        })
        # Inline agent files — one devenv `files.*` entry per agent
        # under `${projectDir}/agents/<name>.agent.md`. Copilot's
        # native agent filename convention is `.agent.md` suffix.
        (lib.mkIf (mergedAgents != {}) {
          files = lib.mapAttrs' (name: content:
            lib.nameValuePair "${cfg.projectDir}/agents/${name}.agent.md" {
              text = lib.ai.agent.renderCopilot name content;
            })
          mergedAgents;
        })
        # agentsDir handled at L2b→L3 above — expansion runs
        # through the existing per-file agents emission.
        # Skills via the user-space walker. devenv's `files.*.source`
        # cannot walk a directory recursively (see the devenv files
        # internals fragment), so we enumerate leaves at eval time
        # via `mkDevenvSkillEntries`. Produces one `files.<path>`
        # entry per leaf file under `${projectDir}/skills/<skill>/`.
        (let
          helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        in {
          files = helpers.mkDevenvSkillEntries cfg.projectDir mergedSkills;
        })
        # mcp-config.json — static write of the merged MCP server
        # pool. Inlined as `text` for consistency with the HM side.
        (lib.mkIf (mergedServers != {}) {
          files."${cfg.configDir}/mcp-config.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Per-instruction files under `<projectDir>/instructions/`. Same
        # transformer as HM, same filter-by-name pattern — nameless entries are
        # composed into the native context file below. `projectDir` must prefix
        # this path too: context/agents/skills already honored an override, but
        # hardcoding `.github` here previously split one declaration across two
        # project roots.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          files = lib.listToAttrs (map (instr: {
              name = "${cfg.projectDir}/instructions/${instr.name}.instructions.md";
              value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
            })
            named);
        })
        # Attrs-shape ai.rules / ai.copilot.rules → instruction files (parity with HM).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
        in {
          files = lib.mapAttrs' (name: rule:
            lib.nameValuePair "${cfg.projectDir}/instructions/${name}.instructions.md" {
              text = fragmentsLib.mkRenderer copilotTransformer {} (rule
                // {
                  paths = aiCommon.ruleMatcher rule;
                  text = aiCommon.readContent rule;
                });
            })
          mergedRules;
        })
        # Global context + unnamed instructions → `<projectDir>/<contextFilename>`
        # (project-scope), composed into one file (the single native context
        # writer; aggregate render retired). Default lands at
        # `.github/copilot-instructions.md`, which Copilot reads natively. A path
        # context with no unnamed instructions stays a `source` symlink.
        (lib.mkIf (hasContext || hasUnnamed) {
          files."${cfg.projectDir}/${cfg.context.filename}" = let
            composed = lib.ai.composeInstructionsFile {
              inherit effectiveContext unnamedInstructions;
              render = lib.ai.transformers.copilot.render;
            };
          in
            if builtins.isPath composed
            then {source = composed;}
            else {text = composed;};
        })
        # settings.json — devenv does NOT support HM-style activation
        # scripts, so the runtime-merge story is different. Devenv
        # projects are project-local (not a shared home dir), so
        # there's no `trusted_folders` preservation problem to solve
        # here. Static JSON write is sufficient.
        #
        # INERT at project scope, same as lsp-config.json above: Copilot
        # reads its settings from `$HOME/.copilot/config.json` and never
        # stats a project-local settings.json. Kept for option parity.
        {
          files."${cfg.configDir}/settings.json".text =
            builtins.toJSON cfg.nativeSettings;
        }
      ];
  };
}
