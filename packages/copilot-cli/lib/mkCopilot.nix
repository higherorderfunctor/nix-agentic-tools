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
}: let
  dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
  wrapCopilotPackage = import ./wrapPackage.nix {inherit lib pkgs;};
  # Both backends install the IDENTICAL wrapper; only the root variable it
  # interpolates differs (`$HOME` vs `$DEVENV_ROOT`). Derived once here and
  # handed to the shared transform's `installPackage` hook, which owns the
  # `home.packages` / `packages` lowering. The helper decides internally
  # whether a wrapper is needed at all, so there is no `needsWrapper`
  # predicate to keep in sync across backends.
  copilotInstallPackageFor = rootVar: {
    cfg,
    mergedServers,
    moduleEnvironmentVariables,
    mergedEnvironmentVariables,
    ...
  }:
    wrapCopilotPackage {
      inherit (cfg) package configDir;
      inherit rootVar;
      mcp = mergedServers != {};
      environmentVariables = moduleEnvironmentVariables // mergedEnvironmentVariables;
    };
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "copilot";
    contextFilename = "copilot-instructions.md";
    contextDescription = ''
      Copilot-specific context appended after `ai.context`. Devenv writes it
      beneath `ai.copilot.projectDir` for github.com's reviewer; Home Manager
      declares the same option for schema parity and warns when it is non-empty,
      because Home Manager cannot deliver this project-scoped guidance.
      When `text` and `source` are defined at different module priorities, the
      higher-priority definition supplies the content whichever field it targets;
      definitions at the same priority conflict. Same-priority `text` definitions
      concatenate in module order. Set `enable = false` to omit this context.
      `filename` controls the artifact name.
    '';
    rulesDescription = ''
      Copilot-specific rules replace top-level `ai.rules` entries at the same
      key; set `enable = false` to suppress an inherited rule. Same-priority
      `text` definitions concatenate in module order.
      Devenv writes them beneath `ai.copilot.projectDir` for github.com's reviewer;
      Home Manager declares the same option for schema parity and warns about
      non-empty rules it cannot deliver.
    '';
    supportedPools = [
      "agents"
      "context"
      "environmentVariables"
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
      # Copilot-specific freeform settings. Consumed by the settings.json leaf
      # reconciliation on both backends, which owns exactly these leaves,
      # retracts one this generation drops, and leaves a runtime-written sibling
      # such as `trusted_folders` alone. Full typed surface (editor
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
        type = lib.types.attrsOf (lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule);
        default = {};
        description = "Typed LSP server definitions; null suppresses a root entry at the same key. Non-null entries translate via `mkCopilotLspConfig` into lsp-config.json on emission (adds fileExtensions mapping).";
      };
      # Baked into the symlinkJoin wrapper on BOTH backends. devenv used to
      # populate its native `env` attrset instead, which exported them into the
      # project shell rather than into Copilot. `attrsOf str` — matching the
      # legacy surface exactly.
      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
        default = {};
        description = "Environment variables baked into the copilot launcher wrapper. Scoped to the Copilot process and the commands it spawns; never exported into the project shell. Null suppresses a root entry at the same key.";
      };
      # Inline agent markdown content. Written under
      # `<configDir>/agents/<name>.md` in HM and
      # `<projectDir>/agents/<name>.agent.md` in devenv. Per-runtime entries
      # replace or suppress top-level `ai.agents`. Can also be populated
      # from a directory via `agentsDir` below (same L2b→L3 pattern as
      # `rulesDir` / `skillsDir`).
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.ai.agent.agentType);
        default = {};
        description = "Agent Markdown or portable semantic records (HM: <configDir>/agents/<name>.md; devenv: <projectDir>/agents/<name>.agent.md). Null suppresses a root entry at the same key.";
      };
      # Directory of `.md` agent files. Each file becomes one entry
      # in `ai.copilot.agents`, keyed by basename minus `.md`. Parity
      # with `rulesDir` / `skillsDir`: expansion runs through the
      # shared replacement semantics, and the on-disk emission dir is NOT taken
      # over wholesale (other derivations may still contribute files alongside).
      agentsDir = lib.mkOption {
        type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
        default = null;
        description = "Directory of `.md` agent files (expanded into `ai.copilot.agents`).";
      };
    };
    # ONE delivery description for both backends.
    #
    # Read the PROVISIONAL note at the top of this file first: `backend` here
    # is still standing in for PRODUCT, so the branches below say `isHm` where
    # they mean "the CLI that reads $HOME" and its absence where they mean "the
    # repository github.com reads". Collapsing the two callbacks does not
    # resolve that conflation; it puts it in one place instead of two.
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
      ...
    }: let
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      isHm = backend == "hm";
      # The CLI keeps agents and skills beside the config it reads; github.com
      # reads them out of the repository instead. One surface, two products.
      nativeDir =
        if isHm
        then cfg.configDir
        else cfg.projectDir;
      # A LITERAL at the declaration site, hashed from the config directory so
      # two configured roots never share ownership records.
      settingsLedger = "json-settings/copilot-settings-${builtins.hashString "sha256" cfg.configDir}.json";
    in
      lib.mkMerge [
        # `projectDir` is shared for option-tree parity and discoverability, but
        # HM cannot give a project-relative path honest semantics. Keep the
        # native default inert and reject customization rather than silently
        # writing a HOME-relative directory Copilot would read as another scope.
        (lib.optionalAttrs isHm {
          assertions = [
            {
              assertion = cfg.projectDir == ".github";
              message = ''
                ai.copilot.projectDir is project-local and cannot be changed
                through Home Manager. Configure it through the devenv module.
              '';
            }
          ];
        })

        # L2b → L3: expand `ai.copilot.agentsDir` into `ai.copilot.agents`.
        # mkDefault lets an explicit per-runtime value win, and the resulting
        # entry replaces a same-key root agent — so `agents` and `agentsDir`
        # are not mutually exclusive, they feed one pool.
        (lib.mkIf (cfg.agentsDir != null) {
          ai.copilot.agents = lib.mapAttrs (_: lib.mkDefault) (
            dirHelpers.agentsFromDir cfg.agentsDir
          );
        })

        # lsp-config.json — typed LSP server definitions.
        #
        # INERT at project scope: Copilot opens `$HOME/.copilot/lsp-config.json`
        # and nothing project-local, and unlike MCP there is no
        # `--additional-lsp-config` to point it here (verified against 1.0.78
        # `--help`). Written anyway for option parity with Home Manager, and
        # deliberately NOT an assertion: `ai.lspServers` is a shared pool, so
        # failing here would break a project that legitimately targets Claude or
        # Kiro with it. Non-empty requests receive the delivery policy's warning.
        (lib.mkIf (mergedLspServers != {}) {
          ai.copilot.files."${cfg.configDir}/lsp-config.json" = {
            content = lib.mkDefault {value = lib.mapAttrs aiCommon.mkCopilotLspConfig mergedLspServers;};
            format = "json";
          };
        })

        # One file per agent. The CLI reads `<name>.md`; github.com requires the
        # native `.agent.md` suffix. Other derivations may still contribute
        # files to the same directory — it is never taken over wholesale.
        (lib.mkIf (mergedAgents != {}) {
          ai.copilot.files = lib.mapAttrs' (name: content:
            lib.nameValuePair "${nativeDir}/agents/${name}${
              if isHm
              then ".md"
              else ".agent.md"
            }" {
              content = lib.mkDefault {text = lib.ai.agent.renderCopilot name content;};
            })
          mergedAgents;
        })

        # mcp-config.json — the wrapper points `--additional-mcp-config` at this
        # exact path on both backends, which is what makes it LIVE where
        # lsp-config.json and settings.json are not.
        (lib.mkIf (mergedServers != {}) {
          ai.copilot.files."${cfg.configDir}/mcp-config.json" = {
            content = lib.mkDefault {
              value.mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
            format = "json";
          };
        })

        # Skills — one entry per tree beside whichever config dir this product
        # reads. Copilot has no upstream skills option on either backend.
        {
          ai.copilot.files = helpers.mkSkillFiles {
            configDir = nativeDir;
            skills = mergedSkills;
          };
        }

        # Instruction files from the rules pool, and the repository context
        # github.com's reviewer consumes. Both are project-scope surfaces the
        # CLI has no equivalent for, so Home Manager stays deliberately inert
        # rather than writing a HOME copy nothing reads.
        (lib.optionalAttrs (!isHm) (lib.mkMerge [
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
          in {
            ai.copilot.files = lib.mapAttrs' (name: rule:
              lib.nameValuePair "${cfg.projectDir}/instructions/${name}.instructions.md" {
                content = lib.mkDefault {
                  text = fragmentsLib.mkRenderer copilotTransformer {} (rule
                    // {
                      paths = rule.matcher;
                      text = aiCommon.readContent rule;
                    });
                };
              })
            mergedRules;
          })
          (lib.mkIf hasMergedContext {
            ai.copilot.files."${cfg.projectDir}/${cfg.context.filename}" =
              aiCommon.contentFileEntry mergedContext;
          })
        ]))

        # settings.json — Copilot rewrites it while it runs (`trusted_folders`,
        # the oauth record), so both backends own only the leaves declared here
        # and leave every native sibling alone. The writer is declared whether
        # or not there are leaves: an empty declaration RETRACTS what the
        # previous generation owned, and with no prior ownership it leaves an
        # externally managed file untouched — which is what a consumer enabling
        # Copilot purely for MCP or skills fanout needs.
        #
        # Devenv uses the same bundle under the project root. This preserves
        # edits there without changing Copilot's project-discovery limitation.
        {
          ai.copilot.activation.copilotSettingsMerge = {
            # Devenv requires a namespace; retain HM's existing ordering name.
            entry = {
              devenv = "ai:copilot:settings-merge";
              hm = "copilotSettingsMerge";
            };
            ledgers.${settingsLedger} = {
              codec = "json";
              path = "${cfg.configDir}/settings.json";
            };
          };
        }
        {
          ai.copilot.files."${cfg.configDir}/settings.json" = {
            content.value = cfg.nativeSettings;
            entry = "copilotSettingsMerge";
            facts.harnessWrites = true;
            format = "json";
            ledger = settingsLedger;
          };
        }
      ];

    devenv = {
      # Package installation. ENV wiring needs no wrapper — devenv has a
      # native `env` attrset. MCP config DOES, and that is why `cfg.package`
      # alone was NOT enough here.
      #
      # Copilot reads MCP config from exactly two places: `$HOME/.copilot/
      # mcp-config.json`, and whatever `--additional-mcp-config` points at.
      # It reads NOTHING from a project-local config dir. Measured by
      # syscall trace against 1.0.78: inside the project it touches only
      # `.github/copilot-instructions.md`, `.github/allowed_models.txt` and
      # `.git`, while `<project>/.config/github-copilot/{mcp,lsp}-config.json`
      # and `settings.json` are never opened or even stat'd. See
      # dev/fragments/ai-clis/copilot-config-delivery.md for the measured
      # discovery behavior and the rejected COPILOT_HOME alternative.
      #
      # `configDir` was always "wrapper-aimed" (see its option comment);
      # devenv adopted it WITHOUT the wrapper, so the rendered
      # mcp-config.json sat on disk and nothing ever loaded it.
      #
      # `environmentVariables` IS passed, same as Home Manager. It used to be
      # withheld here because devenv exports through its native `env` attrset
      # — but that writes the PROJECT SHELL, so every variable also reached
      # the developer's interactive session and everything else running in
      # it. This module does not write the shell environment; process scope
      # is the wrapper's job on both backends.
      installPackage = copilotInstallPackageFor "DEVENV_ROOT";
      options = {
        # Wrapper-aimed config dir. `mcp-config.json` here is LIVE — the
        # `packages` wrapper points `--additional-mcp-config` at it.
        # `lsp-config.json` and `settings.json` are INERT: Copilot reads
        # neither at project scope and offers no flag to inject them
        # (measured, see dev/fragments/ai-clis/copilot-config-delivery.md).
        # They remain declared for HM option parity; the shared delivery
        # diagnostics now warn whenever a consumer supplies either surface.
        # Project-scope files Copilot DOES read
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
    };
    hm = {
      # Package installation. The wrapper itself — including the `\''${HOME}`
      # escaping and the `@` file-path prefix, both of which shipped broken
      # once — lives in ./wrapPackage.nix and is shared with devenv. Read that
      # file before changing anything here; the two details it guards are not
      # visible from the Nix side, and duplicating them is what let the same
      # pair of defects ship twice.
      #
      # HM passes `environmentVariables` through because symlinkJoin is its
      # only export mechanism. It therefore wraps when EITHER MCP servers or
      # env vars are configured; the helper decides that from its arguments,
      # so there is no `needsWrapper` predicate to keep in sync here.
      installPackage = copilotInstallPackageFor "HOME";
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
    };
  }
