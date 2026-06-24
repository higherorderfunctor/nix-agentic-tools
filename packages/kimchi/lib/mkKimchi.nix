# Kimchi-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kimchi AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Kimchi has TWO config trees:
#   ~/.config/kimchi/config.json       — account/CLI settings
#   ~/.config/kimchi/harness/          — agent runtime (settings.json, mcp.json,
#                                         AGENTS.md, skills/)
# The harness tree is mutable at runtime; HM uses activation merge for
# harness/settings.json and static symlink writes for the rest.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

  # Shared per-backend data prep. hm.config and devenv.config derive the
  # same settings/env/instruction values from the merged inputs the
  # transform injects — compute them once here instead of duplicating.
  mkPrep = {
    cfg,
    mergedInstructions,
    mergedEnvironmentVariables,
    topContext,
  }: let
    effectiveContext =
      if cfg.context != null
      then cfg.context
      else topContext;
    hasContext = effectiveContext != null && effectiveContext != "";

    contextText =
      if hasContext
      then
        if builtins.isPath effectiveContext
        then builtins.readFile effectiveContext
        else toString effectiveContext
      else "";

    instructionTexts =
      map (
        frag:
          if frag ? text
          then
            if builtins.isPath frag.text
            then builtins.readFile frag.text
            else toString frag.text
          else ""
      )
      mergedInstructions;

    kimchiEnvVars =
      lib.optionalAttrs (cfg.apiKey != null) {KIMCHI_API_KEY = cfg.apiKey;}
      // lib.optionalAttrs cfg.noUpdateCheck {KIMCHI_NO_UPDATE_CHECK = "1";}
      // lib.optionalAttrs (cfg.telemetry != null) {
        KIMCHI_TELEMETRY_ENABLED =
          if cfg.telemetry
          then "1"
          else "0";
      };
  in {
    filteredSettings = aiCommon.filterNulls cfg.settings;
    filteredHarnessSettings = aiCommon.filterNulls cfg.harnessSettings;
    effectiveEnvVars = mergedEnvironmentVariables // kimchiEnvVars;
    allAgencyTexts = lib.filter (s: s != "") ([contextText] ++ instructionTexts);
  };
in
  lib.ai.app.mkAiApp {
    name = "kimchi";
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults = {
      package = pkgs.ai.kimchi;
      outputPath = null;
    };
    options = {
      context = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
        default = null;
        description = ''
          Kimchi-scope global context. Inline string or path to a file.
          Written to <configDir>/harness/AGENTS.md with no frontmatter.
          When null, falls back to top-level ai.context.
        '';
      };
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/kimchi";
        description = "Config directory relative to HOME / devenv root.";
      };

      settings = lib.mkOption {
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
          Settings written to <configDir>/config.json (HM: activation merge;
          devenv: static write). API key should be injected via environment
          variable, not here.
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
          Settings written to <configDir>/harness/settings.json (HM: activation
          merge; devenv: static write). Kimchi mutates this at runtime, so HM
          merges declarative values on top of the existing file.
        '';
      };

      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Environment variables exported when launching kimchi.";
      };

      apiKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Cast AI API key. Injected via KIMCHI_API_KEY env var instead of config.json.";
      };

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
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedEnvironmentVariables,
        topContext,
        ...
      }: let
        prep = mkPrep {inherit cfg mergedInstructions mergedEnvironmentVariables topContext;};
        inherit (prep) filteredSettings filteredHarnessSettings effectiveEnvVars allAgencyTexts;
        hasEnv = effectiveEnvVars != {};

        # symlinkJoin wrapper for env vars (HM only).
        wrappedPackage = pkgs.symlinkJoin {
          name = "kimchi-wrapped";
          paths = [cfg.package];
          nativeBuildInputs = [pkgs.makeWrapper];
          postBuild = lib.optionalString hasEnv ''
            wrapProgram $out/bin/kimchi \
              ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") effectiveEnvVars)}
          '';
        };
      in
        lib.mkMerge [
          # Package installation — wrapped when env vars are configured.
          {
            home.packages = [
              (
                if hasEnv
                then wrappedPackage
                else cfg.package
              )
            ];
          }

          # config.json activation merge.
          (lib.mkIf (filteredSettings != {}) {
            home.activation.kimchiConfigMerge = lib.hm.dag.entryAfter ["writeBoundary"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/config.json";
              settingsJson = builtins.toJSON filteredSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          })

          # harness/settings.json activation merge (mutable-state
          # reconciliation — Kimchi writes this at runtime).
          (lib.mkIf (filteredHarnessSettings != {}) {
            home.activation.kimchiHarnessSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] (helpers.mkSettingsActivationScript {
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

          # harness/AGENTS.md — orientation context (instructions + top-level context).
          (lib.mkIf (allAgencyTexts != []) {
            home.file."${cfg.configDir}/harness/AGENTS.md".text = lib.concatStringsSep "\n\n" allAgencyTexts;
          })

          # harness/skills/ — Layout B via mkSkillEntries.
          (lib.mkIf (mergedSkills != {}) {
            home.file = helpers.mkSkillEntries "${cfg.configDir}/harness" mergedSkills;
          })
        ];
    };

    devenv = {
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedEnvironmentVariables,
        topContext,
        ...
      }: let
        prep = mkPrep {inherit cfg mergedInstructions mergedEnvironmentVariables topContext;};
        inherit (prep) filteredSettings filteredHarnessSettings effectiveEnvVars allAgencyTexts;
      in
        lib.mkMerge [
          # Package installation.
          {packages = [cfg.package];}

          # Environment variables — devenv native `env`.
          (lib.mkIf (effectiveEnvVars != {}) {
            env = lib.mapAttrs (_: lib.mkDefault) effectiveEnvVars;
          })

          # config.json static write.
          (lib.mkIf (filteredSettings != {}) {
            files."${cfg.configDir}/config.json".text = builtins.toJSON filteredSettings;
          })

          # harness/settings.json static write.
          (lib.mkIf (filteredHarnessSettings != {}) {
            files."${cfg.configDir}/harness/settings.json".text = builtins.toJSON filteredHarnessSettings;
          })

          # harness/mcp.json.
          (lib.mkIf (mergedServers != {}) {
            files."${cfg.configDir}/harness/mcp.json".text = builtins.toJSON {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          })

          # harness/AGENTS.md.
          (lib.mkIf (allAgencyTexts != []) {
            files."${cfg.configDir}/harness/AGENTS.md".text = lib.concatStringsSep "\n\n" allAgencyTexts;
          })

          # harness/skills/ — devenv recursive walk.
          (lib.mkIf (mergedSkills != {}) {
            files = helpers.mkDevenvSkillEntries "${cfg.configDir}/harness" mergedSkills;
          })
        ];
    };
  }
