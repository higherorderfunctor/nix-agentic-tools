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
    (sample // {context = "from /home/u/repo";})
    (sample // {source = "private/x.md";})
    (sample // {replay = ["cat /nix/store/abc-x/y"];})
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
  kimchi = render {
    runtime = "kimchi";
    models = defaults.models // {kimchi = [{vendors = ["anthropic"];}];};
  };
  renders =
    [native external kimchi]
    ++ map (runtime: render {inherit runtime;}) ["codex" "kiro"];
  evidence = lib.concatMap (record:
    [record.context record.source]
    ++ record.replay
    ++ map (capability: capability.evidence) (builtins.attrValues record.capabilities))
  capabilities.observations;
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
    && lib.hasInfix "| Runs own subagents |" native
    && lib.hasInfix "| unknown |" (row "Agent" native)
    && lib.hasInfix "| supported (headless) |" (row "claude -p" native)
    && lib.hasInfix "| unsupported (headless, interactive) |" (row "Workflow" native)
    && lib.hasInfix "| unsupported (headless) |" (row "Agent" kimchi)
    # External sections list only external, introspect and usage nodes.
    && lib.hasInfix "| unknown |" (row "codex exec" external)
    && !(lib.hasInfix "`spawn_agent`" external)
    # A changed shipped launch contract does not borrow the recorded result.
    && lib.all (text: lib.hasInfix "| unknown |" (row "Workflow" text)) changed
    # Evidence stays in the fixtures, out of every runtime's skill.
    && lib.all (text: lib.all (note: !(lib.hasInfix note text)) evidence) renders
    && lib.all (family:
      lib.hasInfix "${family.name} (${family.vendor})" (render {
        models = defaults.models // {claude = [{vendors = lib.unique (map (item: item.vendor) families);}];};
      }))
    families
  );
}
