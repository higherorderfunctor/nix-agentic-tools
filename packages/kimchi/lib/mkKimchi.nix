# Kimchi-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kimchi AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Kimchi has distinct user and project config namespaces. Home Manager writes
# ~/.config/kimchi/{config.json,harness/}; devenv writes only Kimchi's native
# project paths under the repository root. The user harness tree is mutable at
# runtime, so HM uses activation merge for harness/settings.json and static
# symlink writes for the rest. Project harness settings use Kimchi's fixed pi
# config directory, not the consumer's user-global configDir.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};

  # pi 0.85.1 dist/config.js:403 derives CONFIG_DIR_NAME from Kimchi's
  # package.json piConfig.configDir. That fixed project namespace is independent
  # of ai.kimchi.configDir, which selects the Home Manager output root. The
  # pinned binary discovers only that option's default user-global location.
  projectHarnessDir = ".config/kimchi/harness";
  projectContextFilename = "AGENTS.md";

  # Shared per-backend data prep. hm.config and devenv.config derive the
  # same settings/env/context values from the merged inputs the
  # transform injects — compute them once here instead of duplicating.
  mkPrep = {
    cfg,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables ? {},
    mergedContext,
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

    # wrapProgram args: `--set` for non-secret env, `--run` for the
    # runtime secret export. Joined with a single space on the continued
    # line — never a backslash-newline, which breaks multi-arg wrapping.
    wrapArgs =
      lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") effectiveEnvVars
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
      compatibly. Devenv always writes project-root `AGENTS.md`, independent of
      this filename, because that is Kimchi's project context surface.
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
          Home Manager output directory relative to HOME. Kimchi 1.1.27
          discovers only the default location; a non-default value requires a
          compatible package override. Devenv uses Kimchi's fixed project paths.
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
          Kimchi settings written to <configDir>/config.json by Home Manager or
          .kimchi/config.json by devenv. API key should be injected via an
          environment variable, not here.
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
          Harness settings merged into <configDir>/harness/settings.json by Home
          Manager or written to .config/kimchi/harness/settings.json by devenv.
          The project path is fixed by Kimchi and does not follow configDir.
          Kimchi mutates the user file at runtime, so Home Manager merges
          declarative values on top of the existing file.
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

    hm = {
      installPackage = kimchiInstallPackage;
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedSkills,
        mergedEnvironmentVariables,
        moduleEnvironmentVariables,
        mergedContext,
        hasMergedContext,
        ...
      }: let
        prep = mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;};
        inherit (prep) contextEntry filteredSettings filteredHarnessSettings;
      in
        lib.mkMerge [
          # config.json activation merge.
          (lib.mkIf (filteredSettings != {}) {
            home.activation.kimchiConfigMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/config.json";
              settingsJson = builtins.toJSON filteredSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          })

          # harness/settings.json activation merge (mutable-state
          # reconciliation — Kimchi writes this at runtime).
          (lib.mkIf (filteredHarnessSettings != {}) {
            home.activation.kimchiHarnessSettingsMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/harness/settings.json";
              settingsJson = builtins.toJSON filteredHarnessSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          })

          # harness/mcp.json — Claude-compatible format.
          (lib.mkIf (mergedServers != {}) {
            home.file."${cfg.configDir}/harness/mcp.json".text = builtins.toJSON {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          })

          # harness/AGENTS.md — orientation context.
          (lib.mkIf hasMergedContext {
            ai.kimchi.files."${cfg.configDir}/harness/${cfg.context.filename}" = lib.mkDefault contextEntry;
          })

          # harness/skills/ — Layout B via mkSkillEntries.
          (lib.mkIf (mergedSkills != {}) {
            home.file = helpers.mkSkillEntries "${cfg.configDir}/harness" mergedSkills;
          })
        ];
    };

    devenv = {
      installPackage = kimchiInstallPackage;
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedSkills,
        mergedEnvironmentVariables,
        moduleEnvironmentVariables,
        mergedContext,
        hasMergedContext,
        ...
      }: let
        prep = mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;};
        inherit (prep) filteredSettings filteredHarnessSettings;
      in
        lib.mkMerge [
          # Project-scoped Kimchi configuration below is ignored until the
          # project is explicitly or persistently trusted. For unattended runs,
          # set harnessSettings.defaultProjectTrust = "always" in USER scope
          # through Home Manager; a project cannot grant itself trust. Kimchi's
          # direct AGENTS.md discovery is currently the exception to this gate.

          # Project config is a fixed Kimchi namespace, independent of the
          # HOME-relative configDir used by Home Manager.
          (lib.mkIf (filteredSettings != {}) {
            files.".kimchi/config.json".text = builtins.toJSON filteredSettings;
          })

          # Project harness settings follow pi's fixed CONFIG_DIR_NAME.
          (lib.mkIf (filteredHarnessSettings != {}) {
            files."${projectHarnessDir}/settings.json".text = builtins.toJSON filteredHarnessSettings;
          })

          # Exact-cwd project MCP config.
          (lib.mkIf (mergedServers != {}) {
            files.".kimchi/mcp.json".text = builtins.toJSON {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          })

          # Project context lives at the repository root.
          (lib.mkIf hasMergedContext {
            ai.internal.agentsMd.${projectContextFilename} = {
              context = aiCommon.readContent mergedContext;
              hasContent = true;
            };
          })

          # Nearest-ancestor project skills — devenv recursive walk.
          (lib.mkIf (mergedSkills != {}) {
            files = helpers.mkDevenvSkillEntries ".kimchi" mergedSkills;
          })
        ];
    };
  }
