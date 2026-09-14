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
  agent = lib.ai.agent;
  dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
  agentsmd = lib.ai.transformers.agentsmd;
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  roleModelType = lib.types.addCheck lib.types.str (value: builtins.match "[[:space:]]*" value == null);
  roleModelsType = lib.types.addCheck (lib.types.listOf roleModelType) (values: values != []);

  # Shared per-backend data prep. hm.config and devenv.config derive the
  # same settings/env/context values from the merged inputs the
  # transform injects — compute them once here instead of duplicating.
  mkPrep = {
    cfg,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables ? {},
  }: let
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
    # UNDER the consumer's pool, matching every other harness. Explicit env
    # entries also override the telemetry and update-check typed defaults.
    effectiveEnvVars = moduleEnvironmentVariables // kimchiEnvVars // mergedEnvironmentVariables;

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
    mergedEnvironmentVariables,
    moduleEnvironmentVariables,
    ...
  }:
    (mkPrep {inherit cfg mergedEnvironmentVariables moduleEnvironmentVariables;}).package;
  mkConfig = backend: {
    cfg,
    mergedAgents,
    mergedContext,
    hasMergedContext,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables,
    mergedRules,
    mergedServers,
    mergedSkills,
    ...
  }: let
    isHm = backend == "hm";
    prep = mkPrep {inherit cfg mergedEnvironmentVariables moduleEnvironmentVariables;};
    nativeDir =
      if isHm
      then cfg.configDir
      else ".kimchi";
    runtimeDir =
      if isHm
      then "${cfg.configDir}/harness"
      else ".kimchi";
    # Pi's project directory comes from piConfig.configDir in package.json.
    settingsPath = "${
      if isHm
      then cfg.configDir
      else ".config/kimchi"
    }/harness/settings.json";
    rules = lib.mapAttrs (_name: rule:
      agentsmd.renderRule {
        inherit (rule) matcher;
        text = aiCommon.readContent rule;
      })
    mergedRules;
    hasGuidance = hasMergedContext || mergedRules != {};
    guidance = agentsmd.renderKeyed {
      context = aiCommon.readContent mergedContext;
      inherit rules;
    };
    agentEntries = helpers.mkMarkdownEntries runtimeDir "agents" (lib.mapAttrs agent.renderKimchi mergedAgents);
    staticEntries =
      agentEntries
      // lib.optionalAttrs (mergedServers != {}) {
        "${runtimeDir}/mcp.json".text = builtins.toJSON {
          mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
        };
      }
      // lib.optionalAttrs (isHm && hasGuidance) {
        "${runtimeDir}/${cfg.context.filename}".text = guidance;
      }
      // lib.optionalAttrs (!isHm) (
        lib.optionalAttrs (prep.filteredSettings != {}) {
          "${nativeDir}/config.json".text = builtins.toJSON prep.filteredSettings;
        }
        // lib.optionalAttrs (prep.filteredHarnessSettings != {}) {
          "${settingsPath}".text = builtins.toJSON prep.filteredHarnessSettings;
        }
      );
  in
    lib.mkMerge [
      {
        ai.kimchi.agents = lib.mkIf (cfg.agentsDir != null) (
          lib.mapAttrs (_: lib.mkDefault) (dirHelpers.agentsFromDir cfg.agentsDir)
        );
        ai.kimchi.files = lib.mapAttrs (_: lib.mkDefault) staticEntries;
        assertions =
          lib.mapAttrsToList (name: value: {
            assertion = !(agent.isSemantic value) || value.tools == null || value.tools == [];
            message = "ai.kimchi.agents.${name}.tools has no portable Kimchi mapping; use native Kimchi Markdown for tool restrictions or null-suppress this inherited agent.";
          })
          mergedAgents
          ++ [
            {
              assertion = cfg.context.filename == "AGENTS.md";
              message = "ai.kimchi.context.filename must be AGENTS.md, the guidance filename supported by both Kimchi config scopes.";
            }
            {
              assertion = isHm || (aiCommon.filterNulls cfg.nativeSettings.telemetry == {} && cfg.nativeSettings.preferences == {});
              message = "Kimchi reads nativeSettings.telemetry and preferences from user config only; use Home Manager for account settings or ai.kimchi.telemetry for a process-scoped override.";
            }
            {
              assertion = isHm || (cfg.harnessSettings.modelRoles == {} && cfg.harnessSettings.resources == {});
              message = "Kimchi 1.1.21 reads modelRoles and resources from user settings only; manage them with Home Manager. Project harnessSettings can configure Pi settings such as defaultModel and defaultThinkingLevel.";
            }
            {
              assertion = lib.all (role: builtins.elem role ["builder" "compactor" "explorer" "judge" "orchestrator" "planner" "researcher" "reviewer"]) (builtins.attrNames cfg.harnessSettings.modelRoles);
              message = "ai.kimchi.harnessSettings.modelRoles accepts only builder, compactor, explorer, judge, orchestrator, planner, researcher and reviewer.";
            }
            {
              assertion = lib.all (role: !(cfg.harnessSettings.modelRoles ? ${role}) || builtins.isString cfg.harnessSettings.modelRoles.${role}) ["compactor" "orchestrator"];
              message = "ai.kimchi.harnessSettings.modelRoles.orchestrator and compactor require a single provider/model string.";
            }
          ];
      }
      (lib.optionalAttrs isHm {
        home.file = helpers.mkSkillEntries runtimeDir mergedSkills;
        home.activation =
          lib.optionalAttrs (prep.filteredSettings != {}) {
            kimchiConfigMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
              configFile = "${nativeDir}/config.json";
              settingsJson = builtins.toJSON prep.filteredSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          }
          // lib.optionalAttrs (prep.filteredHarnessSettings != {}) {
            kimchiHarnessSettingsMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
              configFile = settingsPath;
              settingsJson = builtins.toJSON prep.filteredHarnessSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          };
      })
      (lib.optionalAttrs (!isHm) {
        files = helpers.mkDevenvSkillEntries runtimeDir mergedSkills;
        ai.internal.agentsMd.${cfg.context.filename} =
          {
            hasContent = lib.mkDefault hasGuidance;
            inherit rules;
          }
          // lib.optionalAttrs hasMergedContext {
            context = aiCommon.readContent mergedContext;
          };
      })
    ];
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "kimchi";
    contextFilename = "AGENTS.md";
    supportedPools = [
      "agents"
      "context"
      "environmentVariables"
      "mcpServers"
      "rules"
      "settings"
      "skills"
    ];
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults = {
      package = pkgs.ai.kimchi;
      outputPath = null;
    };
    options = {
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr agent.agentType);
        default = {};
        description = "Kimchi agent Markdown or semantic records. Same-key values replace root agents; null suppresses them. Use native Markdown for Kimchi tool restrictions.";
      };
      agentsDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = "Directory of native Kimchi agent Markdown files, expanded into ai.kimchi.agents.";
      };
      configDir = lib.mkOption {
        type = lib.types.enum [".config/kimchi"];
        default = ".config/kimchi";
        description = "Fixed upstream user config directory relative to HOME. Kimchi does not support redirecting it; non-default values are rejected.";
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
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = "Skill search paths. Null preserves upstream defaults and user inheritance; an explicit list replaces them, including an empty list.";
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
          Settings written to <configDir>/config.json on HM (activation merge)
          and .kimchi/config.json on devenv (static write). API key should be injected via environment
          variable, not here.
        '';
      };

      harnessSettings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            modelRoles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.either roleModelType roleModelsType);
              default = {};
              description = "Model role assignments as provider/model strings or lists; orchestrator and compactor accept one string.";
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
      config = mkConfig "hm";
      options = {};
    };
    devenv = {
      installPackage = kimchiInstallPackage;
      config = mkConfig "devenv";
      options = {};
    };
  }
