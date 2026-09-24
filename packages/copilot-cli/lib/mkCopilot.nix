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
  # Copilot reads repository settings from this fixed path, whatever
  # `projectDir` says: copilot-cli 1.0.88 opens it (and
  # `settings.local.json` beside it) from the git root of a trusted folder.
  repositorySettingsPath = ".github/copilot/settings.json";
  # Copilot's repository settings schema: each key it accepts there, with the
  # kind of value it accepts. Read from copilot-cli 1.0.88's native
  # `runtime.node`: `userSettingsGovernanceKeys().repo` gives the fifteen
  # names and `userSettingsMetadata()` their kinds. Probing its
  # `repoSettingsLoadWithWarning` showed what each mistake costs. A name
  # outside the schema (`theme`, `banner`, …) is dropped on its own and has
  # no effect, and so is an `autoTier` outside its enum. A known key with a
  # value of the wrong kind makes Copilot ignore the WHOLE file
  # ("Settings config error: respectGitignore: Expected boolean"). devenv
  # rejects all three at evaluation instead of writing them. Nested records
  # (a marketplace source, a hook entry) are checked only as far as their
  # kind; Copilot validates them further. See
  # dev/fragments/ai-clis/copilot-config-delivery.md.
  repositorySettingKinds = let
    enum = values: value: builtins.elem value values;
    stringList = value: builtins.isList value && lib.all builtins.isString value;
    attrsOfKind = kind: value: builtins.isAttrs value && lib.all kind (builtins.attrValues value);
  in {
    autoTier = enum ["balance" "efficiency" "fast" "intelligence"];
    companyAnnouncements = stringList;
    contextTier = enum ["default" "long_context"];
    deniedUrls = stringList;
    disableAllHooks = builtins.isBool;
    disabledMcpServers = stringList;
    disabledSkills = stringList;
    effortLevel = builtins.isString;
    enabledPlugins = attrsOfKind builtins.isBool;
    extraKnownMarketplaces = attrsOfKind builtins.isAttrs;
    hooks = attrsOfKind builtins.isList;
    includeCoAuthoredBy = builtins.isBool;
    mergeStrategy = enum ["merge" "rebase"];
    model = builtins.isString;
    respectGitignore = builtins.isBool;
  };
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
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
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
      # Copilot-specific freeform settings. Each backend reconciles exactly
      # these leaves into the settings file it delivers, retracting one this
      # generation drops and leaving Copilot's own writes alone: `/model`,
      # `/settings` and the other in-CLI toggles rewrite both files. Home
      # Manager owns the user `settings.json`; devenv owns the repository
      # settings file. Folder trust is not among those writes: Copilot records
      # it as `trustedFolders` in `~/.copilot/config.json`. Full typed surface
      # (editor integration, telemetry, typed model selection) is tracked in
      # docs/plan.md "Ideal architecture gate → Absorption backlog" under the
      # copilot-cli absorption item.
      native.settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = "Freeform Copilot settings; null leaves are dropped. Both backends reconcile the declared leaves on activation or shell entry and leave the keys Copilot writes itself alone. Home Manager owns them inside `settings.json` under `configDir`, which every Copilot mode reads. devenv owns them inside `.github/copilot/settings.json`, the fixed repository settings path (independent of `projectDir`). Copilot reads that file from the git root, only in a trusted folder, and reads its `effortLevel` only in interactive sessions. devenv rejects keys outside Copilot's repository schema, and values of the wrong kind, at evaluation. `ai.settings.reasoningEffort` lowers to `effortLevel` here at default priority.";
      };
      # Typed LSP server definitions, merged with the shared
      # `ai.lspServers` pool and rendered by `mkCopilotLspFile`.
      lspServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule);
        default = {};
        description = "Typed LSP server definitions; null suppresses a root entry at the same key. Non-null entries translate via `mkCopilotLspFile` into the `lspServers` envelope: `<configDir>/lsp-config.json` under Home Manager, `<projectDir>/lsp.json` under devenv. Every entry must set `extensions`, because Copilot requires `fileExtensions`, and its name must be non-empty ASCII letters, digits, `_` and `-`, because Copilot rejects the whole file otherwise.";
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
      resolvedSettings,
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
      # LITERALS at the declaration site. The user ledger is hashed from the
      # config directory so two configured roots never share ownership
      # records; the repository file has one fixed path per project.
      settingsLedger =
        if isHm
        then "json-settings/copilot-settings-${builtins.hashString "sha256" cfg.configDir}.json"
        else "json-settings/copilot-repository-settings.json";
      settingsPath =
        if isHm
        then "${cfg.configDir}/settings.json"
        else repositorySettingsPath;
      # A null leaf is how a consumer withholds a key (including the lowered
      # `effortLevel`), so neither backend writes it.
      settings = aiCommon.filterNulls cfg.native.settings;
      unknownRepositorySettings = builtins.filter (key: !(repositorySettingKinds ? ${key})) (builtins.attrNames settings);
      mistypedRepositorySettings = builtins.filter (key: repositorySettingKinds ? ${key} && !(repositorySettingKinds.${key} settings.${key})) (builtins.attrNames settings);
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

        # LSP servers, in the same `lspServers` envelope at both scopes. The
        # CLI reads its USER-level file, `~/.copilot/lsp-config.json`;
        # copilot-cli 1.0.88 also loads the REPOSITORY-level `.github/lsp.json`
        # from the repository root (upstream README "Repository-level
        # configuration"), which is why devenv writes under `projectDir`
        # rather than beside the wrapper-aimed `configDir`.
        (lib.mkIf (mergedLspServers != {}) {
          ai.copilot.files.${
            if isHm
            then "${cfg.configDir}/lsp-config.json"
            else "${cfg.projectDir}/lsp.json"
          } = {
            content.value = aiCommon.mkCopilotLspFile mergedLspServers;
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
        # exact path on both backends, which is what makes it LIVE.
        (lib.mkIf (mergedServers != {}) {
          ai.copilot.files."${cfg.configDir}/mcp-config.json" = {
            content.value.mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
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
                  enable = true;
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

        # Copilot's persisted `effortLevel` takes the normalized enum
        # verbatim ("low" | "medium" | "high" | "xhigh") at user and
        # repository scope. It is a default: an explicit native value, null
        # included, wins. Its REACH differs by backend. Every mode reads the
        # user file Home Manager writes, but only the interactive session
        # reads a repository `effortLevel`: `-p`, `--acp` and `--server`
        # take effort from the user file alone. So devenv delivery is
        # partial, and lib/ai/delivery-warnings.nix says so.
        (lib.mkIf ((resolvedSettings.reasoningEffort or null) != null) {
          ai.copilot.native.settings.effortLevel = lib.mkDefault resolvedSettings.reasoningEffort;
        })

        # settings.json on Home Manager, the repository settings file on
        # devenv. Copilot rewrites both while it runs (`/model`, `/settings`,
        # and their `--repo` forms), so each backend owns only the leaves
        # declared here and leaves every native sibling alone. The writer is
        # declared whether or not there are leaves: an empty declaration
        # RETRACTS what the previous generation owned, and with no prior
        # ownership it leaves an externally managed file untouched — which is
        # what a consumer enabling Copilot purely for MCP or skills fanout
        # needs, and what keeps a committed team file intact.
        {
          ai.copilot.activation.copilotSettingsMerge = {
            entry = {
              devenv = "ai:copilot:settings-merge";
              hm = "copilotSettingsMerge";
            };
            ledgers.${settingsLedger} = {
              codec = "json";
              path = settingsPath;
            };
          };
          ai.copilot.files.${settingsPath} = {
            content.value = settings;
            entry = "copilotSettingsMerge";
            facts.harnessWrites = true;
            format = "json";
            ledger = settingsLedger;
          };
        }

        # The repository schema is narrower than the user one. A name outside
        # it has no effect and a mistyped value voids the whole file, so both
        # fail evaluation here rather than land as a silently dead write.
        (lib.optionalAttrs (!isHm) {
          assertions = [
            {
              assertion = unknownRepositorySettings == [];
              message = ''
                ai.copilot.native.settings sets keys Copilot does not accept in
                repository settings (${repositorySettingsPath}):
                ${lib.concatStringsSep ", " unknownRepositorySettings}.
                Set user-only keys through the Home Manager module instead.
              '';
            }
            {
              assertion = mistypedRepositorySettings == [];
              message = ''
                ai.copilot.native.settings gives these repository settings
                (${repositorySettingsPath}) a value of the wrong kind:
                ${lib.concatStringsSep ", " mistypedRepositorySettings}.
                Copilot ignores the whole file when one value fails its schema.
              '';
            }
          ];
        })
      ];

    devenv = {
      # Package installation. ENV wiring needs no wrapper — devenv has a
      # native `env` attrset. MCP config DOES, and that is why `cfg.package`
      # alone was NOT enough here.
      #
      # Copilot reads MCP config from exactly two places: `$HOME/.copilot/
      # mcp-config.json`, and whatever `--additional-mcp-config` points at.
      # It reads nothing from the wrapper-aimed config dir: a 1.0.78 syscall
      # trace never opened or stat'd
      # `<project>/.config/github-copilot/{mcp,lsp}-config.json` or
      # `settings.json`. What it does read at repository scope sits under
      # `.github/` (`lsp.json`, `copilot/settings.json`). See
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
        # `packages` wrapper points `--additional-mcp-config` at it — and it is
        # the only file devenv writes here. Project-scope files Copilot reads
        # live under `.github/` instead: LSP config under `projectDir`, and
        # repository settings reconciled into the fixed
        # `.github/copilot/settings.json`.
        configDir = lib.mkOption {
          type = lib.types.str;
          default = ".config/github-copilot";
          description = ''
            Wrapper-aimed config dir, relative to the devenv root. Holds
            `mcp-config.json`, which the wrapped `copilot` is pointed at via
            `--additional-mcp-config`.

            Settings are not written here: devenv reconciles them into the
            repository settings file `.github/copilot/settings.json`, and
            writes LSP servers to `<projectDir>/lsp.json`.

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
