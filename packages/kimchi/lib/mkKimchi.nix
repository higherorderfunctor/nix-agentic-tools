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
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};

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
    contextFilename = "AGENTS.md";
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
        description = "Config directory relative to HOME / devenv root.";
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

    # ONE delivery description for both backends. The two callbacks this
    # replaces were near-duplicates of each other: they differed only in which
    # native sink each wrote into, which is exactly the decision the delivery
    # layer now makes from the consumer facts below.
    config = {
      backend,
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
      harness = "${cfg.configDir}/harness";
      # A LITERAL at the declaration site, hashed from the config directory so
      # two configured roots never share ownership records.
      ledgerFor = name: "json-settings/kimchi-${name}-${builtins.hashString "sha256" cfg.configDir}.json";
      # Kimchi rewrites both of its documents while it runs — `/multi-model`
      # and `kimchi resources` write `harness/settings.json` — so the only way
      # to keep both sides' edits is to own the declared leaves inside them.
      # The fact is stated per backend because only Home Manager reconciles
      # them today; devenv still links a whole file, and flipping that is a
      # behavior change of its own.
      reconciled = {
        devenv = false;
        hm = true;
      };
      # A reconciled document is declared even when it has no leaves at all:
      # an empty declaration RETIRES whatever the previous generation owned,
      # which is the whole reason the writer is an identity rather than a
      # product of the files that happen to exist. The declarative backend has
      # nothing to retire and nothing to link, so it omits the file instead.
      document = {
        entry,
        ledger,
        path,
        value,
      }:
        lib.mkIf (backend == "hm" || value != {}) {
          ai.kimchi.files.${path} = {
            inherit entry ledger;
            content.value = value;
            facts.harnessWrites = reconciled;
            format = "json";
          };
        };
    in
      lib.mkMerge [
        # Two writers, two entry names — deliberately NOT one bundle of two
        # targets: nothing orders these against each other, and each name is a
        # consumer-visible ordering contract.
        (lib.optionalAttrs (backend == "hm") {
          ai.kimchi.activation = {
            kimchiConfigMerge.ledgers.${ledgerFor "config"} = {
              codec = "json";
              path = "${cfg.configDir}/config.json";
            };
            kimchiHarnessSettingsMerge.ledgers.${ledgerFor "harness-settings"} = {
              codec = "json";
              path = "${harness}/settings.json";
            };
          };
        })

        (document {
          entry = "kimchiConfigMerge";
          ledger = ledgerFor "config";
          path = "${cfg.configDir}/config.json";
          value = filteredSettings;
        })

        (document {
          entry = "kimchiHarnessSettingsMerge";
          ledger = ledgerFor "harness-settings";
          path = "${harness}/settings.json";
          value = filteredHarnessSettings;
        })

        # harness/mcp.json — Claude-compatible format. Kimchi reads it and
        # never writes it, and follows a store symlink to it, so both facts
        # are the defaults and neither is stated.
        (lib.mkIf (mergedServers != {}) {
          ai.kimchi.files."${harness}/mcp.json" = {
            content.value = {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
            format = "json";
          };
        })

        # harness/AGENTS.md — orientation context.
        (lib.mkIf hasMergedContext {
          ai.kimchi.files."${harness}/${cfg.context.filename}" = contextEntry;
        })

        # harness/skills/ — one entry per skill tree; Home Manager expands the
        # directory and the router expands it for devenv.
        (lib.mkIf (mergedSkills != {}) {
          ai.kimchi.files = helpers.mkSkillFiles {
            configDir = harness;
            skills = mergedSkills;
          };
        })
      ];

    devenv.installPackage = kimchiInstallPackage;
    hm.installPackage = kimchiInstallPackage;
  }
