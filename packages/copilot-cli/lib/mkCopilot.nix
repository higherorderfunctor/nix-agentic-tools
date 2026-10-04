# Copilot-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Copilot AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
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
  wrapCopilotPackage = import ./wrapPackage.nix {inherit lib pkgs;};
  # Copilot reads repository settings from this fixed path, whatever
  # `projectDir` says: copilot-cli 1.0.88 opens it (and
  # `settings.local.json` beside it) from the git root of a trusted folder.
  repositorySettingsPath = ".github/copilot/settings.json";
  # Every key Copilot writes into a settings file is configuration, and it
  # writes by renaming a temporary over the path (measured at copilot-cli
  # 1.0.88: `/settings`, `/model` and `--experimental` for settings.json,
  # `copilot mcp add` for mcp-config.json; its LSP disable toggle writes
  # lsp-config.json, inferred from the binary). That replaces a store
  # symlink or a 0444 file alike, so these files are read-only copies: the
  # next activation or shell entry backs the in-app file up and restores the
  # declaration, where a symlink would block Home Manager's link check. One
  # writer owns every copy through one directory ledger: Home Manager's
  # `configDir` (the user settings.json, mcp-config.json and lsp-config.json),
  # devenv's `.github/copilot` (the repository settings file). It runs while
  # Copilot is disabled too, so a disable retracts the copies.
  configWriter = "materialize-copilot-config";
  configLedger = "materialize/copilot-config.manifest";
  configWriterConfig = {
    backend,
    cfg,
    ...
  }: {
    ai.copilot.activation.${configWriter} = {
      entry = {
        devenv = "ai:copilot:materialize-config";
        hm = configWriter;
      };
      ledgers.${configLedger} = {
        codec = "dir";
        path =
          if backend == "hm"
          then cfg.configDir
          else dirOf repositorySettingsPath;
      };
      pruneEntry.hm = "materialize-copilot-config-prune";
      runWhenDisabled = true;
    };
  };
  copyFields = {
    entry = configWriter;
    format = "json";
    ledger = configLedger;
    method = "copy-ro";
  };
  # Copilot keeps folder trust only in its state file `config.json`
  # (`trustedFolders`, written by `folderTrustAddTrusted`), beside sign-in,
  # session and acknowledgement state it rewrites at will. Home Manager owns
  # that one leaf, `[]` included, and leaves every other key to Copilot. The
  # writer runs while Copilot is disabled, so a disable retracts the leaf.
  # The ledger is hashed from the config directory so two configured roots
  # never share ownership records.
  trustWriter = "copilotTrustedFolders";
  trustLedger = cfg: "json-settings/copilot-config-${builtins.hashString "sha256" cfg.configDir}.json";
  trustPath = cfg: "${cfg.configDir}/config.json";
  trustWriterConfig = {
    backend,
    cfg,
    ...
  }:
    lib.optionalAttrs (backend == "hm") {
      ai.copilot.activation.${trustWriter} = {
        ledgers.${trustLedger cfg} = {
          codec = "json";
          path = trustPath cfg;
        };
        runWhenDisabled = true;
      };
    };
  # github.com's reviewer and cloud agents read the COMMITTED tree, where a
  # store symlink dangles, so on devenv the instruction files and the
  # repository context are read-only copies. Each has a directory ledger that
  # claims only the files it wrote, so a hand-written sibling survives. The
  # writer is declared whether or not there are files and whether or not
  # Copilot is enabled, so both N→0 and a disable retract the copies. Home
  # Manager writes neither surface.
  instructionsWriter = "materialize-copilot-instructions";
  # Where each unit lands, shared by the emitters and `contentTargets`.
  instructionPath = cfg: name: "${cfg.projectDir}/instructions/${name}.instructions.md";
  contextPath = cfg: "${cfg.projectDir}/${cfg.context.filename}";
  instructionsLedger = "materialize/copilot-instructions.manifest";
  contextLedger = "materialize/copilot-context.manifest";
  # The fact is a default, so a consumer can still state its own on one
  # file (to keep a link, say) without a conflicting definition.
  instructionFields = ledger: {
    entry = instructionsWriter;
    facts.symlinkReadable = lib.mkDefault {
      devenv = false;
      hm = true;
    };
    inherit ledger;
  };
  instructionsWriterConfig = {cfg, ...}: {
    ai.copilot.activation.${instructionsWriter} = {
      entry = "ai:copilot:materialize-instructions";
      ledgers = {
        ${contextLedger} = {
          codec = "dir";
          path = cfg.projectDir;
        };
        ${instructionsLedger} = {
          codec = "dir";
          path = "${cfg.projectDir}/instructions";
        };
      };
      runWhenDisabled = true;
    };
  };
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
    launcherEnvironment,
    mergedServers,
    ...
  }:
    wrapCopilotPackage {
      inherit (cfg) package configDir;
      inherit rootVar;
      mcp = mergedServers != {};
      environmentVariables = launcherEnvironment;
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
    defaults = {
      package = pkgs.ai.copilot-cli;
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "copilot-cli";
    };
    agentsDescriptionSuffix = "Each lands at `<configDir>/agents/<name>.md` under Home Manager and `<projectDir>/agents/<name>.agent.md` under devenv.";
    # The builder declares these pool options, `environmentVariables` (baked
    # into ./wrapPackage.nix on both backends) included, and expands
    # `agentsDir` into `agents`; Copilot states where each one lands.
    poolOptions = {
      lspServers.description = "Typed LSP server definitions; null suppresses a root entry at the same key. Non-null entries translate via `mkCopilotLspFile` into the `lspServers` envelope: `<configDir>/lsp-config.json` under Home Manager, `<projectDir>/lsp.json` under devenv. Every entry must set `extensions`, because Copilot requires `fileExtensions`, and its name must be non-empty ASCII letters, digits, `_` and `-`, because Copilot rejects the whole file otherwise.";
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
      # Copilot-specific freeform settings, written as the whole settings
      # file each backend delivers. Folder trust is not a settings key:
      # Copilot records it in its state file, so it has its own option below.
      native.settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = "Freeform Copilot settings; null leaves are dropped. Each backend writes them as a whole read-only file, so a change made inside Copilot (`/settings`, `/model` and their `--repo` forms) lasts only until the next activation or shell entry, which backs it up and restores the declaration. Home Manager always owns `settings.json` under `configDir`, which every Copilot mode reads (`{}` when nothing is declared). devenv owns `.github/copilot/settings.json`, the fixed repository settings path (independent of `projectDir`), only when something is declared. Copilot reads that file from the git root, only in a trusted folder, and reads its `effortLevel` only in interactive sessions. devenv rejects keys outside Copilot's repository schema, and values of the wrong kind, at evaluation. `ai.settings.reasoningEffort` lowers to `effortLevel` here at default priority.";
      };
      trustedFolders = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["/home/me/src"];
        description = "Absolute folders Copilot trusts; a folder covers everything below it. Trust is what makes Copilot read a repository's `.github/copilot/settings.json`, hooks, MCP servers and skills. Home Manager owns the `trustedFolders` key of Copilot's state file `<configDir>/config.json`, empty list included, and restores it on every activation, so a folder trusted at Copilot's prompt stays trusted only until the next switch. devenv rejects a non-empty value: the file is user-global, and devenv never writes `$HOME`. Without Home Manager, Copilot's trust prompt manages the list.";
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
      settingsPath =
        if isHm
        then "${cfg.configDir}/settings.json"
        else repositorySettingsPath;
      # A null leaf is how a consumer withholds a key (including the lowered
      # `effortLevel`), so neither backend writes it.
      settings = aiCommon.filterNulls cfg.native.settings;
      unknownRepositorySettings = builtins.filter (key: !(repositorySettingKinds ? ${key})) (builtins.attrNames settings);
      mistypedRepositorySettings = builtins.filter (key: repositorySettingKinds ? ${key} && !(repositorySettingKinds.${key} settings.${key})) (builtins.attrNames settings);
      relativeTrustedFolders = builtins.filter (folder: !(lib.hasPrefix "/" folder)) cfg.trustedFolders;
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
            {
              assertion = relativeTrustedFolders == [];
              message = "ai.copilot.trustedFolders entries must be absolute paths; Copilot compares trust against the absolute working directory, so ${lib.concatStringsSep ", " relativeTrustedFolders} could never match.";
            }
          ];
        })

        # LSP servers, in the same `lspServers` envelope at both scopes. The
        # CLI reads its USER-level file, `~/.copilot/lsp-config.json`;
        # copilot-cli 1.0.88 also loads the REPOSITORY-level `.github/lsp.json`
        # from the repository root (upstream README "Repository-level
        # configuration"), which is why devenv writes under `projectDir`
        # rather than beside the wrapper-aimed `configDir`.
        # Home Manager's user file is a read-only copy it always owns (see
        # `configWriter`); the repository file is a plain generated file.
        (lib.mkIf (isHm || mergedLspServers != {}) {
          ai.copilot.files.${
            if isHm
            then "${cfg.configDir}/lsp-config.json"
            else "${cfg.projectDir}/lsp.json"
          } =
            {
              content = {
                _generated = true;
                _surface = "settings";
                value = aiCommon.mkCopilotLspFile mergedLspServers;
              };
              format = "json";
            }
            // lib.optionalAttrs isHm copyFields;
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
              content = lib.mkDefault (
                {
                  _generated = true;
                  _surface = "agents";
                }
                // (
                  if lib.ai.agent.isSemantic content
                  then lib.ai.agent.renderFile false name content
                  else {text = lib.ai.agent.renderCopilot name content;}
                )
              );
              format = lib.mkDefault "markdown";
            })
          mergedAgents;
        })

        # mcp-config.json — the wrapper points `--additional-mcp-config` at this
        # exact path on both backends, which is what makes it LIVE. Home
        # Manager's is also the file `copilot mcp add` rewrites, so it is a
        # read-only copy Home Manager always owns (see `configWriter`). devenv's
        # sits in the wrapper-aimed directory, which Copilot never writes.
        (lib.mkIf (isHm || mergedServers != {}) {
          ai.copilot.files."${cfg.configDir}/mcp-config.json" =
            {
              content = {
                _generated = true;
                _surface = "mcpServers";
                value.mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
              };
              format = "json";
            }
            // lib.optionalAttrs isHm copyFields;
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
          {
            ai.copilot.files = aiCommon.mkRuleFiles {
              fields = instructionFields instructionsLedger;
              path = instructionPath cfg;
              rules = mergedRules;
              runtime = "copilot";
              transformer = lib.ai.transformers.copilot.copilotTransformer;
            };
          }
          (lib.mkIf hasMergedContext {
            ai.copilot.files.${contextPath cfg} =
              aiCommon.contentFileEntry mergedContext
              // instructionFields contextLedger;
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
        (lib.mkIf (resolvedSettings.reasoningEffort != null) {
          ai.copilot.native.settings.effortLevel = lib.mkDefault resolvedSettings.reasoningEffort;
        })

        # settings.json on Home Manager, the repository settings file on
        # devenv: a read-only copy of the declaration (see `configWriter`).
        # Home Manager always owns the user-global file; devenv claims the
        # repository file only when something is declared, so enabling
        # Copilot for MCP or skills alone leaves a committed team file intact.
        (lib.mkIf (isHm || settings != {}) {
          ai.copilot.files.${settingsPath} =
            copyFields
            // {
              content = {
                _generated = true;
                _surface = "settings";
                value = settings;
              };
            };
        })

        # Folder trust, the one leaf Home Manager owns in Copilot's state file
        # (see `trustWriter`).
        (lib.optionalAttrs isHm (helpers.mkReconciledDocument {
          content = {
            _generated = true;
            _surface = "settings";
            value.trustedFolders = cfg.trustedFolders;
          };
          format = "json";
          ledger = trustLedger cfg;
          path = trustPath cfg;
          runtime = "copilot";
          writer = trustWriter;
        }))

        # The repository schema is narrower than the user one. A name outside
        # it has no effect and a mistyped value voids the whole file, so both
        # fail evaluation here rather than land as a silently dead write.
        (lib.optionalAttrs (!isHm) {
          assertions = [
            # An explicit exclusion, not a silent no-op: trust lives only in
            # the user's HOME, which devenv never writes.
            {
              assertion = cfg.trustedFolders == [];
              message = ''
                ai.copilot.trustedFolders is user scope: Copilot reads folder trust only from ~/.copilot/config.json, and devenv writes only inside the project.
                Set it with Home Manager. Without Home Manager that file is Copilot's own, and its trust prompt saves the decision there.
              '';
            }
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

    # Home Manager writes neither surface, so nothing there can be switched off.
    contentTargets = {
      backend,
      cfg,
      mergedRules,
      ...
    }:
      lib.optionalAttrs (backend == "devenv") {
        context = contextPath cfg;
        rules = lib.mapAttrs (name: _rule: instructionPath cfg name) mergedRules;
      };
    migrationConfig = args:
      lib.mkMerge [
        (configWriterConfig args)
        (trustWriterConfig args)
        (lib.optionalAttrs (args.backend == "devenv") (instructionsWriterConfig args))
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
        # repository settings in the fixed `.github/copilot/settings.json`.
        configDir = lib.mkOption {
          type = lib.types.str;
          default = ".config/github-copilot";
          description = ''
            Wrapper-aimed config dir, relative to the devenv root. Holds
            `mcp-config.json`, which the wrapped `copilot` is pointed at via
            `--additional-mcp-config`.

            Settings are not written here: devenv writes them to the
            repository settings file `.github/copilot/settings.json`, and
            LSP servers to `<projectDir>/lsp.json`.

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
