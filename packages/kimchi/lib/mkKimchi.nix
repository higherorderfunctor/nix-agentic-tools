# Kimchi-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kimchi AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Kimchi has distinct user and project config namespaces. Home Manager writes
# ~/.config/kimchi/{config.json,harness/}; devenv writes only Kimchi's native
# project paths under the repository root. Both backends reconcile the two
# mutable JSON documents by leaf; the remaining files are immutable and
# symlink-readable.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  userScopeOnlyHarnessSettingKeys = import ./user-scope-only-harness-settings.nix;

  # pi 0.85.1 derives CONFIG_DIR_NAME from Kimchi's packaged piConfig.configDir.
  # That fixed project namespace is independent of ai.kimchi.configDir, which
  # selects the Home Manager output root.
  projectHarnessDir = ".config/kimchi/harness";
  projectContextFilename = "AGENTS.md";

  # The delivery function and package hook need the same settings, env and
  # context values from merged inputs; prepare them once.
  mkPrep = {
    cfg,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables ? {},
    mergedContext,
    requiredProjectRoot ? null,
  }: let
    contextEntry = aiCommon.contentFileEntry mergedContext;

    # Non-secret env vars — baked into the wrapper via `--set`.
    kimchiEnvVars =
      lib.optionalAttrs cfg.noUpdateCheck {KIMCHI_NO_UPDATE_CHECK = "1";}
      // lib.optionalAttrs (cfg.telemetry != null) {
        KIMCHI_TELEMETRY_ENABLED =
          if cfg.telemetry
          then "1"
          else "0";
      };
    # Module-contributed defaults (e.g. the sandbox-safe GIT_SSH_COMMAND) sit
    # UNDER the consumer's pool, matching every other harness. `kimchiEnvVars`
    # stays last: those are derived from typed options, not free-form entries.
    effectiveEnvVars = moduleEnvironmentVariables // mergedEnvironmentVariables // kimchiEnvVars;

    # The Cast AI key is a secret: read it from its decrypted file (or
    # helper) at launch via the repo's shared credential snippet, so it is
    # never serialized into the world-readable /nix/store. Same mechanism
    # the MCP servers use (lib/mcp.nix); sops-nix / agenix agnostic.
    credSnippet =
      if cfg.apiKey != null
      then mcpLib.mkCredentialsSnippet pkgs {apiKey.envVar = "KIMCHI_API_KEY";} {inherit (cfg) apiKey;}
      else "";

    # Kimchi resolves project config, MCP servers, and harness settings from
    # process.cwd() exactly. Changing cwd here would also change the directory
    # seen by Kimchi's tools, so reject descendant launches instead.
    exactCwdGuard = lib.optionalString (requiredProjectRoot != null) ''
      kimchi_project_root=${lib.escapeShellArg requiredProjectRoot}
      if [ "$(${pkgs.coreutils}/bin/realpath -- "$PWD")" != "$(${pkgs.coreutils}/bin/realpath -- "$kimchi_project_root")" ]; then
        printf '%s\n' "Kimchi project files are configured at $kimchi_project_root; run kimchi from that devenv root." >&2
        exit 1
      fi
    '';

    # wrapProgram args: `--set` for non-secret env, `--run` for the
    # runtime secret export. Joined with a single space on the continued
    # line — never a backslash-newline, which breaks multi-arg wrapping.
    wrapArgs =
      lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") effectiveEnvVars
      ++ lib.optional (exactCwdGuard != "") "--run ${lib.escapeShellArg exactCwdGuard}"
      ++ lib.optional (credSnippet != "") "--run ${lib.escapeShellArg credSnippet}";

    wrappedPackage = pkgs.symlinkJoin {
      name = "kimchi-wrapped";
      paths = [cfg.package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = lib.optionalString (wrapArgs != []) ''
        wrapProgram $out/bin/kimchi \
          ${lib.concatStringsSep " " wrapArgs}
      '';
    };
  in {
    inherit contextEntry;
    filteredSettings = aiCommon.filterNulls cfg.nativeSettings;
    filteredHarnessSettings = aiCommon.filterNulls cfg.harnessSettings;
    package =
      if wrapArgs != []
      then wrappedPackage
      else cfg.package;
  };
  # Both backends install the same prepared wrapper (env + the runtime secret,
  # which is cat'd at launch so it never enters the store). Handed to the
  # shared transform's `installPackage` hook, which owns the `home.packages` /
  # `packages` lowering. The second `mkPrep` application re-evaluates (Nix caches
  # thunks, not function applications at distinct call sites) but
  # yields the identical derivation, so it adds no build.
  kimchiInstallPackage = {
    cfg,
    mergedContext,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables,
    ...
  }:
    (mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;}).package;

  kimchiDevenvInstallPackage = {
    cfg,
    config,
    mergedContext,
    mergedEnvironmentVariables,
    mergedServers,
    moduleEnvironmentVariables,
    ...
  }: let
    hasExactCwdProjectFiles =
      aiCommon.filterNulls cfg.nativeSettings
      != {}
      || aiCommon.filterNulls cfg.harnessSettings != {}
      || mergedServers != {};
  in
    (mkPrep {
      inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;
      requiredProjectRoot =
        if hasExactCwdProjectFiles
        then config.devenv.root
        else null;
    }).package;
  # One delivery description for both backends. The two former callback bodies
  # were near-duplicates: they differed only in which native sink each wrote,
  # which is exactly the decision the delivery layer now makes from the
  # consumer facts below.
  kimchiDelivery = backend: {
    cfg,
    hasMergedContext,
    mergedContext,
    mergedEnvironmentVariables,
    mergedServers,
    mergedSkills,
    moduleEnvironmentVariables,
    ...
  }: let
    prep = mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;};
    inherit (prep) contextEntry filteredHarnessSettings filteredSettings;
    isDevenv = backend == "devenv";
    configPath =
      if isDevenv
      then ".kimchi/config.json"
      else "${cfg.configDir}/config.json";
    harness =
      if isDevenv
      then projectHarnessDir
      else "${cfg.configDir}/harness";
    harnessSettingsPath = "${harness}/settings.json";
    mcpPath =
      if isDevenv
      then ".kimchi/mcp.json"
      else "${harness}/mcp.json";
    skillRoot =
      if isDevenv
      then ".kimchi"
      else harness;
    userScopeOnlyHarnessSettings = lib.intersectLists userScopeOnlyHarnessSettingKeys (builtins.attrNames filteredHarnessSettings);
    # A LITERAL at the declaration site, hashed from the config directory so
    # two configured roots never share ownership records.
    ledgerFor = name: path: "json-settings/kimchi-${name}-${builtins.hashString "sha256" path}.json";
    # Kimchi rewrites both of its documents while it runs — `/multi-model`
    # and `kimchi resources` write `harness/settings.json` — so the only way
    # to keep both sides' edits is to own the declared leaves inside them.
    # A reconciled document is declared even when it has no leaves at all:
    # an empty declaration RETIRES whatever the previous generation owned,
    # which is the whole reason the writer is an identity rather than a
    # product of the files that happen to exist, on either backend.
    document = {
      entry,
      ledger,
      path,
      value,
    }: {
      ai.kimchi.files.${path} = {
        inherit entry ledger;
        content.value = value;
        facts.harnessWrites = true;
        format = "json";
      };
    };
  in
    lib.mkMerge [
      # Two writers, two entry names — deliberately NOT one bundle of two
      # targets: nothing orders these against each other, and each name is a
      # consumer-visible ordering contract.
      {
        assertions = lib.optional isDevenv {
          assertion = userScopeOnlyHarnessSettings == [];
          message = ''
            ai.kimchi.harnessSettings contains settings Kimchi reads only from user scope: ${lib.concatStringsSep ", " userScopeOnlyHarnessSettings}.
            Under devenv, either set with HM, or configure inside the harness so it writes to user global.
            Home Manager delivers these declaratively by reconciling config.json and harness/settings.json; a /nix/store symlink would break Kimchi's runtime writes. Configuring inside Kimchi persists the decision or setting in its user-global harness files.
          '';
        };
        ai.kimchi.activation = {
          kimchiConfigMerge = {
            # Devenv requires a namespace; HM ordering names stay stable.
            entry = {
              devenv = "ai:kimchi:config-merge";
              hm = "kimchiConfigMerge";
            };
            ledgers.${ledgerFor "config" configPath} = {
              codec = "json";
              path = configPath;
            };
          };
          kimchiHarnessSettingsMerge = {
            entry = {
              devenv = "ai:kimchi:harness-settings-merge";
              hm = "kimchiHarnessSettingsMerge";
            };
            ledgers.${ledgerFor "harness-settings" harnessSettingsPath} = {
              codec = "json";
              path = harnessSettingsPath;
            };
          };
        };
      }

      (document {
        entry = "kimchiConfigMerge";
        ledger = ledgerFor "config" configPath;
        path = configPath;
        value = filteredSettings;
      })

      (document {
        entry = "kimchiHarnessSettingsMerge";
        ledger = ledgerFor "harness-settings" harnessSettingsPath;
        path = harnessSettingsPath;
        value = filteredHarnessSettings;
      })

      # harness/mcp.json — Claude-compatible format. Kimchi reads it and
      # never writes it, and follows a store symlink to it, so both facts
      # are the defaults and neither is stated.
      (lib.mkIf (mergedServers != {}) {
        ai.kimchi.files.${mcpPath} = {
          content.value = {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
          format = "json";
        };
      })

      # User harness context stays runtime-owned. Project context joins the one
      # shared repository AGENTS.md owner used by Codex and Kiro.
      (lib.mkIf hasMergedContext (
        if isDevenv
        then {
          ai.internal.agentsMd.${projectContextFilename} = {
            context = aiCommon.readContent mergedContext;
            hasContent = true;
          };
        }
        else {
          ai.kimchi.files."${harness}/${cfg.context.filename}" = contextEntry;
        }
      ))

      # harness/skills/ — one entry per skill tree; Home Manager expands the
      # directory and the router expands it for devenv.
      (lib.mkIf (mergedSkills != {}) {
        ai.kimchi.files = helpers.mkSkillFiles {
          configDir = skillRoot;
          skills = mergedSkills;
        };
      })
    ];
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "kimchi";
    contextFilename = projectContextFilename;
    contextDescription = ''
      Kimchi-specific context appended after `ai.context`. Home Manager emits
      the configured filename under its harness directory, although pinned
      Kimchi discovers only `AGENTS.md` there unless the package is overridden
      compatibly. Devenv always writes project-root `AGENTS.md`.
    '';
    supportedPools = [
      "context"
      "environmentVariables"
      "mcpServers"
      "settings"
      "skills"
    ];
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults = {
      package = pkgs.ai.kimchi;
      outputPath = null;
    };
    options = {
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/kimchi";
        description = ''
          Home Manager output directory relative to HOME. The pinned Kimchi
          discovers only the default location; a non-default value requires a
          compatible package override. Devenv uses fixed project paths.
        '';
      };

      nativeSettings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            telemetry = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {
                  enabled = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable telemetry reporting in config.json.";
                  };
                };
              };
              default = {};
              description = "Telemetry settings.";
            };
            llmEndpoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "LLM endpoint override.";
            };
            skillPaths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Additional skill search paths.";
            };
            preferences = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {};
              };
              default = {};
              description = "User preferences (freeform).";
            };
          };
        };
        default = {};
        description = ''
          Kimchi settings reconciled by leaf in <configDir>/config.json on Home
          Manager activation or .kimchi/config.json on devenv shell entry. API
          keys should be injected through the environment instead.
        '';
      };

      harnessSettings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            modelRoles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  provider = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Model provider for this role.";
                  };
                  model = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Model identifier for this role.";
                  };
                };
              });
              default = {};
              description = "Model role assignments (e.g. orchestrator, planner).";
            };
            resources = lib.mkOption {
              type = lib.types.attrsOf lib.types.bool;
              default = {};
              description = "Resource toggles (e.g. hooks.bash, tools.web_search).";
            };
          };
        };
        default = {};
        description = ''
          Harness settings reconciled by leaf in
          <configDir>/harness/settings.json on Home Manager activation or
          .config/kimchi/harness/settings.json on devenv shell entry. Kimchi
          mutates the user file at runtime, so both backends preserve unowned
          settings and retract retired leaves.
        '';
      };

      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
        default = {};
        description = "Environment variables exported when launching kimchi. Null suppresses a root entry at the same key.";
      };

      # Cast AI key — a runtime credential (file | helper), exported as
      # KIMCHI_API_KEY at launch. Reuses the repo's shared MCP credential
      # pattern (lib/mcp.nix) so the secret is read from its decrypted file
      # at runtime and never lands in the /nix/store. Set exactly one of
      # apiKey.file (sops-nix/agenix path) or apiKey.helper.
      apiKey = mcpLib.mkCredentialsOption "KIMCHI_API_KEY";

      noUpdateCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable background self-update probe via KIMCHI_NO_UPDATE_CHECK.";
      };

      telemetry = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override telemetry via KIMCHI_TELEMETRY_ENABLED env var.";
      };
    };

    devenv = {
      config = kimchiDelivery "devenv";
      installPackage = kimchiDevenvInstallPackage;
    };
    hm = {
      config = kimchiDelivery "hm";
      installPackage = kimchiInstallPackage;
    };
  }
