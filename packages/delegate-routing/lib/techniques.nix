{
  claudeUsageScript,
  codexUsageScript,
}: let
  claudeCommand = ''claude -p --model <id> --effort <effort> "<prompt>"'';
  codexCommand = ''codex exec --model <slug> --config 'model_reasoning_effort="<level>"' --json --output-last-message <out>.md - < <prompt-file>'';
  usageNotes = "prints the usage schema: windows{usedPercent,remainingPercent,resetsAt,status,windowSeconds}, balances, bonuses";
in {
  claude = {
    Agent = {
      kind = "subagent";
      launchRoute = false;
      modes = ["interactive" "headless"];
      notes = "`effort` pins low to max; `model` stays enum-locked to aliases unless an agent definition file supplies a full id";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Claude `Agent`: depth 3 below main (claude:depth)
      runsOwnSubagents = "supported (headless)";
    };
    "Agent with generated agent file" = {
      kind = "subagent";
      modelArg = "the generated agent file pinning";
      modes = ["interactive" "headless"];
      notes = "call `Agent` with `subagent_type: \"<family>\"`: the generated `.claude/agents/<family>.md` pins the full model id and the family's default effort when the agent-file format accepts it; otherwise bind the canonical launch effort in the call or intentionally omit it for null. delegate-routing is the skill that authorizes setting effort; call `effort` overrides the file. `CLAUDE_CODE_SUBAGENT_EFFORT` is an existing lower-precedence fallback, not a launch route.";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Claude `Agent`: depth 3 below main (claude:depth)
      runsOwnSubagents = "supported (headless)";
    };
    Workflow = {
      kind = "workflow";
      modelArg = "full model id";
      modes = ["interactive" "headless"];
      notes = "`agent(prompt, {model, effort})` per node; accepts full model ids, including ids outside the Agent enum, from configured model-picker rows (the ids operator proxy routes publish); a single node is the way to pin one delegate; pass `args` again on resume (open regression anthropics/claude-code#103657); keep the working directory fixed for a run (a cwd change orphans persisted scripts, anthropics/claude-code#99517)";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Claude `Workflow` fn 14: nodes lack Agent/Workflow (claude:wf_allowed)
      runsOwnSubagents = "unsupported (headless)";
    };
    "claude -p" = {
      command = claudeCommand;
      # Offline Claude 2.1.319 capture: tools=[], normal auth retained, hooks disabled.
      pickerCommand = {
        command =
          builtins.replaceStrings
          ["<id>" ''"<prompt>"'']
          ["<model>" ''--tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '{"disableAllHooks":true}' --disable-slash-commands --no-session-persistence --system-prompt 'Return JSON only.' < <prompt-file> > <output-file>'']
          claudeCommand;
        toolFree = true;
      };
      kind = "external";
      modelArg = "full model id";
      modes = ["headless"];
      notes = "omit --effort for Haiku; use the harness's own background mechanism, never nohup or a trailing &";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Claude `Agent`: a `claude -p` main nests 3 levels (claude:depth)
      runsOwnSubagents = "supported (headless)";
    };
    models = {
      kind = "introspect";
      notes = "read the Agent tool's `model` enum and any `maxEffortLevel` settings clamp";
    };
    usage = {
      command = claudeUsageScript;
      kind = "usage";
      notes = usageNotes;
    };
  };
  codex = {
    "codex exec" = {
      command = codexCommand;
      # Offline codex-cli 0.167.0 capture: no `tools` key and no tool item reach the
      # Responses request. Flags alone leave code-mode exec and wait; the helper's
      # one-model <catalog-file> (tool_mode direct, shell disabled, no apply_patch)
      # removes them. One live ChatGPT-authenticated check is still owed.
      pickerCommand = {
        command =
          builtins.replaceStrings
          ["<slug>" "<level>" "<out>.md" "--json"]
          ["<model>" "<effort>" "<output-file>" ''-c model_catalog_json=<catalog-file> -c tools.experimental_request_user_input.enabled=false -c agents.enabled=false -c 'web_search="disabled"' --disable goals --disable view_image --disable shell_tool --disable image_generation --disable apps --disable plugins --disable tool_suggest --ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check --sandbox read-only -c 'approval_policy="never"' --json'']
          codexCommand;
        toolFree = true;
      };
      kind = "external";
      modelArg = "slug";
      modes = ["headless"];
      notes = "launch from cwd with a full brief and a fresh output path; use no -C, --worktree, bypass or trust flags. The terminal `-` already closes stdin, so do not add `</dev/null` (it wins the redirect and sends an empty prompt); check the exit code and `turn.failed`/`error` events, then verify the output";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Codex V2 `spawn_agent`: `codex exec` child and grandchild run (codex:R1.v1-close-tree, codex:R1.v2-nested-depth-zero)
      runsOwnSubagents = "supported (headless)";
    };
    models = {
      command = ''jq -r '.models[] | select(.visibility=="list") | .slug' "''${CODEX_HOME:-$HOME/.codex}/models_cache.json"'';
      kind = "introspect";
      notes = "read efforts from `.supported_reasoning_levels`; if the client-side cache is stale or missing, fall back to `codex app-server` `model/list`";
    };
    spawn_agent = {
      kind = "subagent";
      modelArg = "slug";
      modes = ["interactive" "headless"];
      notes = ''`collaboration.spawn_agent` with `fork_turns: "none"`, `model`, `reasoning_effort`, `task_name` and the full brief; without fork_turns "none" it inherits and refuses overrides; never select `ultra`'';
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Codex V2 `spawn_agent`: no depth cap, 3 seen (codex:R1.v2-nested-depth-zero)
      runsOwnSubagents = "supported (headless)";
    };
    usage = {
      command = codexUsageScript;
      kind = "usage";
      notes = usageNotes;
    };
  };
  kimchi = {
    Agent = {
      kind = "subagent";
      modelArg = "`--list-models` id";
      modes = ["acp" "headless" "interactive"];
      notes = "always pass `thinking` explicitly: an omitted one falls back to the persona default, not the parent's level; an omitted `model` uses the session's, or the role model when multi-model is on; with multi-model on, an explicit `model` must be in the allowed pool; runs in the background by default when a UI is attached";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Kimchi `Agent`: depth 1, child has no Agent tools (claude:s1-fg-pins)
      runsOwnSubagents = "unsupported (headless)";
    };
    "kimchi -p" = {
      command = ''kimchi -p --mode json --no-session --model <id> --thinking <level> "<prompt>"'';
      kind = "external";
      modelArg = "`--list-models` id";
      modes = ["headless"];
      notes = "thinking levels: off, minimal, low, medium, high, xhigh, max. An unknown model exits 1, but an invalid --thinking only warns and runs, so validate it yourself; loads the project AGENTS.md, so no prompt is small; the answer is the last assistant message in the `agent_end` event's `messages`";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md Kimchi `Agent` and background step: a `kimchi -p` main spawns Agent (claude:s1-fg-pins, claude:w1-workflow)
      runsOwnSubagents = "supported (headless)";
    };
    models = {
      command = "kimchi --list-models";
      kind = "introspect";
      notes = "pass its `model` column to `--model`; the `thinking` column says whether `--thinking` applies";
    };
  };
  kiro = {
    invoke_sub_agent = {
      kind = "subagent";
      # docs/delegates/system-prompt.md: pr-hl-invoke, pr-acp-invoke.
      modes = ["headless" "acp"];
      notes = "inherits the session model";
      pinsEffort = false;
      pinsModel = false;
    };
    "kiro-cli chat" = {
      command = ''kiro-cli chat --no-interactive --model <id> --effort <effort> "<prompt>"'';
      kind = "external";
      # docs/delegates/tools.md: codex:R3 v3-headless.
      modelArg = "model_id";
      modes = ["headless"];
      notes = "models with no effort control ignore --effort";
      pinsEffort = true;
      pinsModel = true;
      # docs/delegates/tools.md: v3 headless child and grandchild execute (codex:R3 v3-headless)
      runsOwnSubagents = "supported (headless)";
    };
    models = {
      command = "kiro-cli chat --list-models -f json | jq -r '.models[].model_id'";
      kind = "introspect";
      notes = "effort choices: run `kiro-cli acp --agent-engine v3 --auth-method cli` and query `_kiro/config/template` over ACP for the session";
    };
    orchestrate_subagent = {
      kind = "subagent";
      # docs/delegates/tools.md: claude:h3-all, codex:R6; system-prompt.md: pr-acp-orch.
      modes = ["interactive" "acp"];
      notes = "some ACP clients enable it in place of invoke_sub_agent";
      pinsEffort = false;
      pinsModel = false;
    };
    run_workflow = {
      kind = "workflow";
      # docs/delegates/system-prompt.md: pr-hl-wf, pr-acp-wf; tools.md: claude:k-wfpins.
      modelArg = "modelId";
      modes = ["interactive" "headless" "acp"];
      notes = "`modelId`/`effortLevel` per step (step > workflow > session); hidden unless workflows are enabled; an unknown modelId fails mid-run, so put pinned steps first";
      pinsEffort = true;
      pinsModel = true;
    };
  };
}
