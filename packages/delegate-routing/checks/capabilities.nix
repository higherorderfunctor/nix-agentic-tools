{
  harness,
  lib,
  ...
}: let
  capabilities = import ../lib/capabilities.nix {inherit lib;};
  defaults = import ../lib/defaults.nix {
    inherit lib;
    claudeUsageScript = "claude-usage";
    codexUsageScript = "codex-usage";
  };
  selection = import ../lib/select-families.nix {inherit lib;};
  families = selection.flatten defaults.families;
  techniques = lib.mapAttrs (_: nodes:
    lib.mapAttrs (_: node:
      {
        command = null;
        enable = true;
      }
      // node)
    nodes)
  defaults.techniques;
  render = overrides:
    import ../lib/render.nix ({
        inherit lib techniques;
        inherit (defaults) families models;
        runtime = "claude";
      }
      // overrides);
  native = render {};
  external = render {extraRuntimes = ["codex"];};
  custom = render {
    techniques =
      techniques
      // {
        claude =
          techniques.claude
          // {
            consumer = techniques.claude.Agent;
          };
      };
  };
  changed = map (override:
    render {
      techniques =
        techniques
        // {
          claude =
            techniques.claude
            // {
              Workflow = techniques.claude.Workflow // override;
            };
        };
    }) [
    {command = "custom-workflow";}
    {kind = "subagent";}
    {modes = ["interactive"];}
    {pinsEffort = false;}
    {pinsModel = false;}
  ];
  row = name: text:
    lib.findFirst (line: lib.hasPrefix "| `${name}` |" line) "" (lib.splitString "\n" text);
  sample = lib.head capabilities.observations;
  replaceCapability = name: record:
    sample // {capabilities = sample.capabilities // {${name} = record;};};
  invalid = [
    (sample // {date = "2026/10/04";})
    (sample // {mode = "batch";})
    (sample
      // {
        observed = {
          effort = null;
          model = 1;
        };
      })
    (sample // {replay = [];})
    (sample
      // {
        requested = {
          effort = true;
          model = null;
        };
      })
    (sample // {requested = {model = null;};})
    (replaceCapability "available" {
      evidence = "bad enum";
      result = "yes";
    })
    (replaceCapability "available" {result = "unknown";})
    (replaceCapability "nestingDepth" {
      evidence = "negative depth";
      result = "supported";
      value = -1;
    })
    (replaceCapability "nestingDepth" {
      evidence = "non-integer depth";
      result = "supported";
      value = "5";
    })
    (replaceCapability "nestingDepth" {
      evidence = "missing supported depth";
      result = "supported";
      value = null;
    })
    (replaceCapability "nestingDepth" {
      evidence = "unknown depth";
      result = "unknown";
      value = 5;
    })
  ];
  workflow = capabilities.find "claude" "Workflow" "interactive";
  workflowPin = capabilities.format workflow "pinsModel";
  # Exercise the catalog renderer directly; Copilot is not a module runtime.
  copilot = render {
    runtime = "copilot";
    models = defaults.models // {copilot = [{vendors = ["openai"];}];};
    techniques =
      techniques
      // {
        copilot.fleet = {
          command = "copilot --fleet -p <prompt>";
          enable = true;
          kind = "external";
          modes = ["headless"];
          notes = "Consumer-declared Fleet technique with recorded help evidence";
          pinsEffort = true;
          pinsModel = true;
        };
      };
  };
  kimchi = render {
    runtime = "kimchi";
    models = defaults.models // {kimchi = [{vendors = ["anthropic"];}];};
  };
  kiro = render {
    runtime = "kiro";
    models = defaults.models // {kiro = [{vendors = ["anthropic"];}];};
  };
in {
  checks.module-delegate-routing-capabilities = harness.mkTest "delegate-routing-capabilities" (
    # Force every shipped fixture, including observations outside the runtime catalog.
    capabilities.observations
    != []
    && lib.all capabilities.validate capabilities.observations
    && lib.all (record: !capabilities.validate record) invalid
    && lib.all (name: !capabilities.validate (builtins.removeAttrs sample [name])) (builtins.attrNames sample)
    && capabilities.find "missing-runtime" "Agent" "interactive" == null
    && capabilities.find "claude" "Agent" "acp" == null
    && capabilities.format null "available" == "unknown (no recorded observation)"
    && lib.hasInfix "acp: unknown" (row "Agent" native)
    && lib.hasInfix "| `Agent` | subagent |" native
    && lib.hasInfix "| Runs own subagents |" native
    && lib.all (mode: lib.hasInfix "${mode}:" (row "Agent" native)) ["acp" "headless" "interactive"]
    && lib.hasInfix "declared, not observed" (row "consumer" custom)
    && !(lib.hasInfix "**consumer /" custom)
    && lib.hasInfix "subagent (inside the external root)" (row "spawn_agent" external)
    && lib.hasInfix "Runtime can own delegates" external
    && lib.hasInfix "headless: supported" (row "spawn_agent" external)
    && lib.hasInfix "headless: unknown" (row "spawn_agent" external)
    && lib.all (text:
      lib.hasInfix "declared, not observed" (row "Workflow" text)
      && !(lib.hasInfix "**Workflow / interactive evidence:**" text))
    changed
    && lib.hasInfix "**Workflow / interactive evidence:**" native
    && lib.hasInfix "requested model=opus, observed model=claude-opus-5" workflowPin
    && lib.hasInfix workflow.source workflowPin
    && lib.hasInfix workflow.date workflowPin
    && lib.hasInfix "Requested controls:" native
    && lib.hasInfix "Observed controls:" native
    && lib.hasInfix "**fleet / headless evidence:**" copilot
    && lib.hasInfix "runtime-evidence.md: Copilot findings (installed help)" copilot
    && lib.hasInfix "HELP exposes per-agent model config and inherit; resolved values unknown." copilot
    && lib.hasInfix "HELP exposes effortLevel config and inherit; resolved values unknown." copilot
    && lib.hasInfix "headless: unknown;" (row "fleet" copilot)
    && !(lib.hasInfix "headless: unknown (declared, not observed)" (row "fleet" copilot))
    && lib.hasInfix "SOURCE transports explicit model; effective backend unknown." kimchi
    && lib.hasInfix "acp: supported (5)" (row "invoke_sub_agent" kiro)
    && lib.all (family:
      lib.hasInfix "${family.name} (${family.vendor})" (render {
        models = defaults.models // {claude = [{vendors = lib.unique (map (item: item.vendor) families);}];};
      }))
    families
  );
}
