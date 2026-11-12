{backend}: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  # Copilot's sizing controls are not established.
  supportedRuntimes = ["claude" "codex" "kimchi" "kiro"];
  # This flake's build unless the overlay is applied (ai.internal.roots).
  defaults = config.ai.internal.roots.delegate-routing-content;
  portable = config.ai.programs.delegate-routing;
  vocabulary = import ../lib/vocabulary.nix;
  inherit (vocabulary) delegateKinds;
  tierNames = vocabulary.tiers;
  techniqueType = import ../lib/technique-type.nix {inherit lib;};
  familyFunctions = import ../lib/select-families.nix {inherit lib;};
  opencodeGo = import ../lib/opencode-go.nix {inherit lib;};
  inherit (familyFunctions) select;
  entryDefaults = import ../lib/entries.nix {inherit lib;};
  entryTypes = import ../lib/entry-type.nix {inherit lib;};
  entries = import ../lib/resolve-entries.nix {inherit lib;};
  entryOptions = entryTypes.options;
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib pkgs;};
  reminder = import ../lib/reminder.nix {inherit lib pkgs;};
  workflowResumeDirectory = "~/.claude/projects";
  # Home Manager has no Kimchi hook file.
  hookRuntimes = ["claude" "codex" "kiro"] ++ lib.optional (backend == "devenv") "kimchi";
  reminderProgram = (import ../../../lib/ai/program.nix {inherit lib;}).mkProgram {
    name = "delegate-routing";
    inherit supportedRuntimes;
    options.reminder.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to deliver the per-turn delegation reminder.";
    };
  };
  reminderEnabled = runtime: (reminderProgram.resolve config runtime).reminder.enable;
  reminderRuntimes = lib.filter (runtime: lib.hasAttrByPath ["ai" runtime "hooks"] options) hookRuntimes;
  reminderHookEnabled = runtime: sourceEnabled runtime && reminderEnabled runtime;
  resolved = runtime: let
    local = portable.runtimes.${runtime};
  in {
    routing = entries.resolveRouting portable.routing local.routing;
    skill = entries.resolveSkill portable.skill local.skill;
    workflows = entries.resolveWorkflows portable.workflows local.workflows;
  };
  # The effective entry owns both the rule and its short per-turn request.
  reminderText = runtime: let
    orchestrator = (resolved runtime).routing."Orchestrator session";
    firstParagraph =
      lib.replaceStrings ["\n"] [" "]
      (lib.head (lib.splitString "\n\n" orchestrator.text));
  in
    portable.reminder.text + lib.optionalString orchestrator.enable "\n${firstParagraph}";
  enabled = runtime:
    config.ai.programs.delegate-routing.runtimes.${runtime}.enable
    or null;
  # Mirror program.nix's B4 resolveOverride: null inherits the portable value; keep in sync.
  programEnabled = runtime:
    if enabled runtime == null
    then config.ai.programs.delegate-routing.enable
    else enabled runtime;
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  sourceEnabled = runtime: programEnabled runtime && runtimeEnabled runtime;
  requiredTargets = runtime:
    lib.unique ([runtime] ++ portable.runtimes.${runtime}.extraRuntimes ++ portable.runtimes.${runtime}.manualExternalDelegates);
  poolReaders = map (pool: pool.usage.runtime) (lib.filter (pool: pool.usage != null) (builtins.attrValues portable.pools));
  redact = import ../../../lib/redact {inherit lib;};
  usageFor = runtime: let
    # The runtime's selection already carries the root fields it inherits.
    selection = config.ai.${runtime}.settings.inference or {instance = null;};
    instances = lib.attrByPath ["ai" "cliproxyapi" "instances"] {} config;
    selected =
      if selection.instance == null
      then null
      else
        (import ../../ai-module/lib/instances.nix {inherit lib;}).select {
          inherit instances;
          name = selection.instance;
          option = "ai.${runtime}.settings.inference.instance";
          owner = "cliproxyapi";
        };
    key =
      if selected == null || selected ? problem
      then null
      else instances.${selection.instance}.settings.management.secret-key;
    managementKeyFiles =
      if redact.isReference key
      then redact.filePaths key
      else [];
    prefix = "DELEGATE_USAGE_CPA_${lib.toUpper runtime}";
  in
    lib.optionalAttrs (managementKeyFiles != []) {
      "${prefix}_MANAGEMENT_KEY_FILE" = lib.mkDefault (lib.head managementKeyFiles);
      "${prefix}_URL" = lib.mkDefault selected.url;
    };
  usageEnvironment = runtime:
    lib.foldl' (environment: target: environment // usageFor target) {}
    (lib.filter (target: builtins.elem target ["claude" "codex"]) (lib.unique (requiredTargets runtime ++ poolReaders)));
  # Workflow tweaks default on only when ai.kiro.cli.package != null: the
  # managed package is what carries the patched KAS bundle.
  reachesKiro = lib.any (runtime:
    sourceEnabled runtime
    && builtins.elem "kiro" (requiredTargets runtime))
  supportedRuntimes;
  kiroTweaksDeclared = lib.hasAttrByPath ["ai" "kiro" "cli" "tweaks"] options;
  models = lib.genAttrs supportedRuntimes (runtime: config.ai.programs.delegate-routing.runtimes.${runtime}.models);
  techniques = familyFunctions.effectiveTechniques config;
  agentFiles = import ../lib/agent-files.nix {inherit lib;};
  inference = import ../../../lib/ai/inference {inherit lib;};
  pickerRows = (import ../../claude-code/lib/inference.nix {inherit lib pkgs;}).modelPickerOptions {
    inherit backend;
    resolvedInference = inference.resolve (config.ai.internal.inferenceInstances or {}) (config.ai.claude.settings.inference or {
      instance = null;
      url = null;
    });
  };
  resolvedAgentFiles = agentFiles.resolve (
    if config.ai.catalog.resolved.runtimes ? claude
    then config.ai.catalog.resolved.modelsFor "claude"
    else agentFiles.facts.models ++ map (row: row.model) pickerRows
  ) (select portable.families models.claude);
  runtimeSkill = runtime:
    defaults.passthru.mkSkill {
      inherit runtime models techniques resolvedAgentFiles;
      catalog = config.ai.catalog.resolved;
      inherit (portable) families pools;
      inherit (resolved runtime) routing skill workflows;
      inherit (portable.runtimes.${runtime}) extraRuntimes manualExternalDelegates picker sessionPool;
    };
  observationCommand = defaults.passthru.mkObservation {
    catalog = config.ai.catalog.resolved;
    poolDefinitions = config.ai.catalog.pools;
    inherit techniques;
    budgets = portable.pools;
    inherit (portable) pacing;
  };
  flattenedFamilies = familyFunctions.flatten portable.families;
  vendors = lib.unique (map (family: family.vendor) flattenedFamilies);
  names = lib.unique (map (family: family.name) flattenedFamilies);
  tiers = lib.unique (map (family: family.tier) flattenedFamilies);
  # Runtime maps are package-owned, outside the factory's null-as-inherit controls.
  runtimeOptions = runtime:
    entryOptions
    // {
      extraRuntimes = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.remove runtime supportedRuntimes));
        default = [];
        description = "Auto-selectable external delegate runtimes. Each named runtime must be enabled through ai.<runtime>.enable.";
      };
      manualExternalDelegates = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.remove runtime supportedRuntimes));
        default = [];
        description = "Describe external delegates for explicit user requests only; never auto-select them. Each named runtime must be enabled through ai.<runtime>.enable. Manual-only takes precedence over extraRuntimes.";
      };
      picker.entries = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            effort = lib.mkOption {
              type = lib.types.enum vocabulary.effortLevels;
              description = "Pinned picker effort.";
            };
            model = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Explicit concrete model id resolved to one configured family.";
            };
            technique = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Enabled external one-shot technique with a picker command.";
            };
          };
        });
        default =
          map (lib.getAttrs ["effort" "model" "technique"])
          (import ../lib/routing-view.nix {
            inherit lib runtime models techniques resolvedAgentFiles;
            catalog = config.ai.catalog.resolved;
            inherit (portable) families pools;
            inherit (portable.runtimes.${runtime}) extraRuntimes manualExternalDelegates;
          }).pickerEntries;
        description = "Ordered one-shot model pickers. Empty or unproven tool removal warns and uses tier/pool fallback. Exact tuples must be unique.";
      };
      sessionPool = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum (builtins.attrNames portable.pools));
        default = null;
        description = "Registered budget spent by this runtime's session; null warns that the buffer rule cannot be certified. Set the actual pool for proxied runtimes.";
      };
      models = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            families = lib.mkOption {
              type = lib.types.listOf (lib.types.enum names);
              default = [];
              description = "Family names to select.";
            };
            tiers = lib.mkOption {
              type = lib.types.listOf (lib.types.enum tiers);
              default = [];
              description = "Capability tiers to select.";
            };
            vendors = lib.mkOption {
              type = lib.types.listOf (lib.types.enum vendors);
              default = [];
              description = "Vendors to select.";
            };
          };
        });
        default = defaults.models.${runtime};
        description = "Alternative family selectors. Each non-empty field must match; an empty selector is invalid. Kimchi and Kiro require an explicit selection when their skill is enabled.";
      };
      techniques = lib.mkOption {
        type = lib.types.attrsOf techniqueType;
        default = {};
        description = "Structured delegation, model inspection and usage techniques.";
      };
    };
in {
  options.ai.programs.delegate-routing =
    entryOptions
    // {
      families = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule {
          options = {
            avoidFor = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Tasks this family should avoid.";
            };
            defaultEffort = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum vocabulary.effortLevels);
              default = null;
              description = "Default effort for every launch technique and generated agent file; null omits the pin when the observed technique supports omission.";
            };
            effort = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Delegate effort guidance for consumer {families} table entries; defaultEffort supplies launch defaults.";
            };
            example = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Concrete current model id by target harness, shaped like pools; that harness's launch route names it in place of the match pattern, and a target with no entry names the pattern instead.";
            };
            match = lib.mkOption {
              type = lib.types.str;
              description = "Normalized live model id pattern, resolved using the runtime's own spelling.";
            };
            orchestration = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Orchestration suitability shown in consumer {families} table entries, such as \"default orchestrator\" or \"reserved for hard work\"; empty shows nothing.";
            };
            pool = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Subscription pool guidance, such as how much use empties the pool. OpenCode Go presets fill it from opencodeGo.plan.";
            };
            pools = lib.mkOption {
              type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
              default = {};
              description = "Budget pool by target runtime. A null binding means no pool is known for that reach.";
            };
            tier = lib.mkOption {
              type = lib.types.enum tierNames;
              description = "Capability tier.";
            };
            useFor = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Tasks suited to this family.";
            };
          };
        }));
        default = {};
        description = "Portable model families keyed by vendor and family name. Override any field or add a family.";
      };
      opencodeGo.plan = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum opencodeGo.plans);
        default = null;
        example = "go-plus";
        description = "Your OpenCode Go plan. The opencode-go preset families then show that plan's documented monthly limit per model; null shows none.";
      };
      opencodeGo.pool = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Registered budget pool bound to every OpenCode Go preset on runtimes selecting that vendor. Setting opencodeGo.plan alone only supplies pool text; it does not bind a pool. When a plan is set, the module requires this option to name a registered pool and refuses evaluation otherwise.";
      };
      pacing.pools = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.weight = lib.mkOption {
            type = lib.types.numbers.positive;
            default = 1;
            description = "Multiplier applied to ordinary allowance pace in the inspection preview.";
          };
        });
        default = {};
        description = "Allowance weights keyed by shared catalog pool; reset and credit policy are not delivered yet.";
      };
      pools = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Budget description shown in consumer {pools} table entries.";
            };
            usage = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  runtime = lib.mkOption {
                    type = lib.types.enum supportedRuntimes;
                    description = "Enabled runtime whose usage technique reads this pool.";
                  };
                  technique = lib.mkOption {
                    type = lib.types.str;
                    description = "Enabled usage technique with a non-empty command for this pool.";
                  };
                };
              });
              default = null;
              description = "Canonical usage reader for this budget, resolved from the runtime's techniques.";
            };
            window = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  limit = lib.mkOption {
                    type = lib.types.numbers.positive;
                    description = "Configured monthly allowance, not an observed remaining balance.";
                  };
                  resetDay = lib.mkOption {
                    type = lib.types.ints.between 1 28;
                    description = "Day of the calendar month when the allowance resets, in UTC.";
                  };
                  unit = lib.mkOption {
                    type = lib.types.nonEmptyStr;
                    description = "Unit of the configured allowance.";
                  };
                };
              });
              default = null;
              description = "Configured monthly window for an unmeasured budget; current use remains unknown. A usage reader takes precedence.";
            };
          };
        });
        default = {};
        description = "Portable budget pools. Each pool needs a usage reader or a configured monthly window.";
      };
      reminder = lib.mkOption {
        type = aiTypes.optionalTextSource {
          defaultContent.text = reminder.defaultText;
          description = "the per-turn delegate-routing reminder";
          enableDefault = true;
        };
        default = {};
        description = ''
          Per-turn UserPromptSubmit reminder in the user's voice. Claude and Codex
          receive JSON additionalContext on both backends; Kimchi on devenv only.
          Kiro receives plain text on both. Set runtimes.<runtime>.reminder.enable
          to false to withhold it from that runtime. This text or source supplies
          the base request. An enabled effective routing."Orchestrator session"
          appends its first paragraph as one line; replace that entry's text or
          source to change the line, or disable the entry to omit it.
        '';
      };

      runtimes =
        lib.genAttrs supportedRuntimes (runtime:
          runtimeOptions runtime // reminderProgram.module.options.ai.programs.delegate-routing.runtimes.${runtime});
    };

  # Emit one portable enable option and skills/rules for each supported runtime.
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "delegate-routing";
      enableDescription = "delegate model and effort sizing skills and rule";
      inherit backend supportedRuntimes;
      skills = {runtime, ...}: {
        delegate-routing = "${runtimeSkill runtime}";
      };
      rules = {runtime, ...}:
        import ../router.nix {
          inherit lib;
          entries = (resolved runtime).routing;
          inherit (resolved runtime) workflows;
        };
    })
    {
      config =
        lib.setAttrByPath (
          if backend == "hm"
          then ["home" "packages"]
          else ["packages"]
        )
        (lib.optional (lib.any sourceEnabled supportedRuntimes) observationCommand);
    }
  ];

  config = {
    ai = lib.mkMerge [
      {
        claude.agents =
          lib.mkIf techniques.claude."Agent with generated agent file".enable
          (lib.mapAttrs (_: entry: lib.mkDefault (agentFiles.render entry)) resolvedAgentFiles);
      }
      (lib.genAttrs supportedRuntimes (runtime:
        lib.mkIf (sourceEnabled runtime)
        (lib.setAttrByPath (
          if runtime == "claude"
          then ["native" "settings" "env"]
          else lib.drop 2 (optionPaths.pool runtime "environmentVariables")
        ) (usageEnvironment runtime))))
      (lib.mkIf (sourceEnabled "claude" && techniques.claude.Workflow.enable) {
        # Plain lists coexist with consumer directories; mkForce opts out.
        claude.native.settings.permissions.additionalDirectories = [workflowResumeDirectory];
      })
      (lib.optionalAttrs (backend == "devenv") (lib.mkIf (
          sourceEnabled "claude"
          && techniques.claude.Workflow.enable
          # No managed package means no wrapper to add the flag named by the hook.
          && lib.attrByPath ["ai" "claude" "package"] null config != null
        ) {
          claude = {
            # A consumer mkForce that drops the directory leaves the wrapper
            # without the flag, so the notice would name a flag nobody added.
            hooks.SessionStart = lib.mkIf (builtins.elem workflowResumeDirectory config.ai.claude.untrustedProjectAdditionalDirectories) [
              {
                hooks = [
                  {
                    command = import ../lib/workflow-resume.nix {
                      inherit lib pkgs;
                      directory = workflowResumeDirectory;
                    };
                  }
                ];
              }
            ];
            untrustedProjectAdditionalDirectories = [workflowResumeDirectory];
          };
        }))
      {
        programs.delegate-routing = {
          families = lib.mkMerge [
            (lib.mapAttrsRecursive (_: lib.mkDefault) defaults.families)
            (lib.mkIf (portable.opencodeGo.plan != null) {
              ${opencodeGo.vendor} =
                lib.mapAttrs (name: _: {pool = lib.mkDefault (opencodeGo.poolHint portable.opencodeGo.plan portable.families.${opencodeGo.vendor}.${name}.match);})
                opencodeGo.families;
            })
            (lib.mkIf (portable.opencodeGo.pool != null) {
              ${opencodeGo.vendor} =
                lib.mapAttrs (_: _: {
                  pools =
                    lib.genAttrs (lib.filter (runtime:
                      lib.any (family: family.vendor == opencodeGo.vendor)
                      (select portable.families models.${runtime}))
                    supportedRuntimes)
                    (_: lib.mkDefault portable.opencodeGo.pool);
                })
                opencodeGo.families;
            })
          ];
          routing = lib.mapAttrsRecursive (_: lib.mkDefault) entryDefaults.routing;
          skill = lib.mapAttrsRecursive (_: lib.mkDefault) entryDefaults.skill;
          workflows = lib.mapAttrsRecursive (_: lib.mkDefault) entryDefaults.workflows;
        };
      }
      {
        programs.delegate-routing.runtimes = lib.genAttrs supportedRuntimes (runtime: {
          techniques = lib.mapAttrsRecursive (_: lib.mkDefault) defaults.techniques.${runtime};
        });
      }
      # Guarded on the declaration: a consumer without the Kiro module has no
      # ai.kiro.cli.tweaks to set.
      (lib.optionalAttrs kiroTweaksDeclared {
        kiro.cli = lib.mkIf (reachesKiro && config.ai.kiro.cli.package != null) {
          tweaks = lib.mkIf config.ai.kiro.cli.workflows.enable {
            relativeFileCheckPaths = lib.mkDefault true;
            stripVendorWorktreeSteering = lib.mkDefault true;
          };
        };
      })
      (lib.genAttrs reminderRuntimes (runtime:
        lib.mkIf (reminderHookEnabled runtime)
        (reminder.hooks.${runtime} (reminderText runtime))))
    ];
    warnings =
      map (runtime: "ai.programs.delegate-routing.runtimes.${runtime}.reminder.enable is true, but this backend cannot deliver a reminder hook for ${runtime}. Disable that runtime reminder or use devenv.")
      (lib.filter (runtime: sourceEnabled runtime && portable.runtimes.${runtime}.reminder.enable == true && !(builtins.elem runtime hookRuntimes)) supportedRuntimes)
      ++ map (runtime: "ai.programs.delegate-routing.runtimes.${runtime}.sessionPool is null; session budget unknown and the buffer rule cannot be certified.")
      (lib.filter (runtime: sourceEnabled runtime && portable.runtimes.${runtime}.sessionPool == null) supportedRuntimes);
    assertions =
      [
        {
          assertion = !(builtins.elem "kiro" reminderRuntimes && reminderHookEnabled "kiro") || config.ai.kiro.hooksDir == null;
          message = "ai.programs.delegate-routing: the Kiro reminder cannot coexist with ai.kiro.hooksDir. Set runtimes.kiro.reminder.enable = false or move those hooks out of hooksDir.";
        }
        {
          assertion = !lib.any reminderHookEnabled reminderRuntimes || portable.reminder._sourceWins || portable.reminder.text != "";
          message = "ai.programs.delegate-routing.reminder.text must be non-empty when a runtime reminder hook is enabled, unless a source supplies the content.";
        }
        {
          assertion = lib.allUnique (map (family: family.name) flattenedFamilies);
          message = "ai.programs.delegate-routing.families: family names must be unique across vendors.";
        }
      ]
      ++ lib.concatLists (lib.mapAttrsToList (name: pool: let
          path = "ai.programs.delegate-routing.pools.${lib.strings.escapeNixIdentifier name}";
          reader = pool.usage;
          node =
            if reader == null
            then null
            else techniques.${reader.runtime}.${reader.technique} or null;
        in [
          {
            assertion = reader != null || pool.window != null;
            message = "${path}: set usage or window for this pool.";
          }
          {
            assertion = reader == null || runtimeEnabled reader.runtime;
            message = "${path}.usage.runtime: the reader runtime must be enabled through ai.<runtime>.enable.";
          }
          {
            assertion = reader == null || (node != null && node.enable && node.kind == "usage" && node.command != null && lib.trim node.command != "");
            message = "${path}.usage.technique: reference an enabled usage technique with a non-empty command.";
          }
        ])
        portable.pools)
      ++ [
        {
          assertion = portable.opencodeGo.plan == null || portable.opencodeGo.pool != null;
          message = "ai.programs.delegate-routing.opencodeGo.pool is null; the Go preset families would have no pool and rank on fit only. Set opencodeGo.pool to the registered pool key, e.g. \"opencode-go\".";
        }
        {
          assertion = portable.opencodeGo.plan == null || portable.opencodeGo.pool == null || builtins.hasAttr portable.opencodeGo.pool portable.pools;
          message = "ai.programs.delegate-routing.opencodeGo.pool: unknown pool `${toString portable.opencodeGo.pool}`; set it to a registered pool key, e.g. \"opencode-go\", declared under ai.programs.delegate-routing.pools.";
        }
      ]
      ++ lib.concatMap (family:
        lib.mapAttrsToList (target: pool: let
          path = "ai.programs.delegate-routing.families.${family.vendor}.${family.name}.pools.${target}";
        in
          if !(builtins.elem target supportedRuntimes)
          then {
            assertion = false;
            message = "${path}: `${target}` is not a runtime; bind pools by target runtime name.";
          }
          else {
            assertion = pool == null || builtins.hasAttr pool portable.pools;
            message = "${path}: unknown pool `${toString pool}`; declare it under ai.programs.delegate-routing.pools.";
          })
        family.pools)
      flattenedFamilies
      ++ lib.concatMap (runtime: let
        path = "ai.programs.delegate-routing.runtimes.${runtime}";
      in
        lib.concatMap (list:
          map (target: {
            assertion = !(sourceEnabled runtime) || runtimeEnabled target;
            message = "${path}.${list} includes `${target}`, but ai.${target}.enable is false. Enable it with ${lib.concatStringsSep "." (optionPaths.enable target)} = true.";
          })
          portable.runtimes.${runtime}.${list}) ["extraRuntimes" "manualExternalDelegates"]
        ++ map (target: {
          assertion = !(sourceEnabled runtime) || select portable.families models.${target} != [];
          message = "ai.programs.delegate-routing.runtimes.${target}.models must select at least one configured family when its program and runtime are enabled or an enabled runtime references it.";
        })
        (requiredTargets runtime)
        ++ map (target: let
          overlaps = opencodeGo.overlaps (select portable.families models.${target});
        in {
          assertion = !(sourceEnabled runtime) || overlaps == [];
          message = "ai.programs.delegate-routing.runtimes.${target}.models selects an opencode-go preset and another family matching the same OpenCode Go catalog model: ${lib.concatStringsSep "; " overlaps}. Select one of them per runtime, or narrow a family's match.";
        })
        (requiredTargets runtime)
        ++ map (selector: {
          assertion = selector.vendors != [] || selector.tiers != [] || selector.families != [];
          message = "${path}.models contains an empty selector; specify vendors, tiers or families.";
        })
        models.${runtime}
        ++ lib.concatLists (lib.mapAttrsToList (name: node: let
            delegate = builtins.elem node.kind delegateKinds;
            techniquePath = "${path}.techniques.${lib.strings.escapeNixIdentifier name}";
          in [
            {
              assertion = (node.pinsModel != null) == delegate && (node.pinsEffort != null) == delegate;
              message = "${techniquePath}: pinsModel and pinsEffort must be non-null exactly for workflow, subagent and external techniques.";
            }
            {
              assertion = node.kind != "external" || node.command != null;
              message = "${techniquePath}.command is required for an external technique.";
            }
          ])
          techniques.${runtime}))
      supportedRuntimes;
  };
}
