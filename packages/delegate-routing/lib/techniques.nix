{
  claudeUsageScript,
  codexUsageScript,
}: {
  claude = {
    Agent = {
      kind = "subagent";
      modes = ["interactive" "headless"];
      notes = "`model` takes an alias from the tool's enum; effort is inherited";
      pinsEffort = false;
      pinsModel = true;
    };
    Workflow = {
      kind = "workflow";
      modes = ["interactive" "headless"];
      notes = "`agent(prompt, {model, effort})` per node; a single node is the way to pin one delegate";
      pinsEffort = true;
      pinsModel = true;
    };
    "claude -p" = {
      command = ''claude -p --model <id> --effort <effort> "<prompt>"'';
      kind = "external";
      modes = ["headless"];
      notes = "omit --effort for Haiku; use the harness's own background mechanism, never nohup or a trailing &";
      pinsEffort = true;
      pinsModel = true;
    };
    models = {
      kind = "introspect";
      notes = "read the Agent tool's `model` enum and any `maxEffortLevel` settings clamp";
    };
    usage = {
      command = claudeUsageScript;
      kind = "usage";
      notes = "read `five_hour.utilization` and `seven_day.utilization`";
    };
  };
  codex = {
    "codex exec" = {
      command = ''codex exec --model <slug> --config 'model_reasoning_effort="<level>"' --json --output-last-message <out>.md - < <prompt-file>'';
      kind = "external";
      modes = ["headless"];
      notes = "launch from cwd with a full brief and a fresh output path; use no -C, --worktree, bypass or trust flags. The terminal `-` already closes stdin, so do not add `</dev/null` (it wins the redirect and sends an empty prompt); check the exit code and `turn.failed`/`error` events, then verify the output";
      pinsEffort = true;
      pinsModel = true;
    };
    models = {
      command = ''jq -r '.models[] | select(.visibility=="list") | .slug' "''${CODEX_HOME:-$HOME/.codex}/models_cache.json"'';
      kind = "introspect";
      notes = "read efforts from `.supported_reasoning_levels`; if the client-side cache is stale or missing, fall back to `codex app-server` `model/list`";
    };
    spawn_agent = {
      kind = "subagent";
      modes = ["interactive" "headless"];
      notes = ''`collaboration.spawn_agent` with `fork_turns: "none"`, `model`, `reasoning_effort`, `task_name` and the full brief; `fork_turns: "none"` and positive integer partial-history forks accept model and effort overrides; full-history `fork_turns: "all"` (the default) inherits and refuses overrides; never select `ultra`'';
      pinsEffort = true;
      pinsModel = true;
    };
    usage = {
      command = codexUsageScript;
      kind = "usage";
      notes = "read `usedPercent`, `remainingPercent`, `resetsAt`";
    };
  };
  kimchi = {
    Agent = {
      kind = "subagent";
      modes = ["acp" "headless" "interactive"];
      notes = "always pass `thinking` explicitly: an omitted one falls back to the persona default, not the parent's level; an omitted `model` uses the session's, or the role model when multi-model is on; with multi-model on, an explicit `model` must be in the allowed pool; runs in the background by default when a UI is attached";
      pinsEffort = true;
      pinsModel = true;
    };
    "kimchi -p" = {
      command = ''kimchi -p --mode json --no-session --model <id> --thinking <level> "<prompt>"'';
      kind = "external";
      modes = ["headless"];
      notes = "thinking levels: off, minimal, low, medium, high, xhigh, max. An unknown model exits 1, but an invalid --thinking only warns and runs, so validate it yourself; loads the project AGENTS.md, so no prompt is small; the answer is the last assistant message in the `agent_end` event's `messages`";
      pinsEffort = true;
      pinsModel = true;
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
      modes = ["headless" "acp"];
      notes = "inherits the session model";
      pinsEffort = false;
      pinsModel = false;
    };
    "kiro-cli chat" = {
      command = ''kiro-cli chat --no-interactive --model <id> --effort <effort> "<prompt>"'';
      kind = "external";
      modes = ["headless"];
      notes = "models with no effort control ignore --effort";
      pinsEffort = true;
      pinsModel = true;
    };
    models = {
      command = "kiro-cli chat --list-models -f json | jq -r '.models[].model_id'";
      kind = "introspect";
      notes = "effort choices: run `kiro-cli acp --agent-engine v3 --auth-method cli` and query `_kiro/config/template` over ACP for the session";
    };
    orchestrate_subagent = {
      kind = "subagent";
      modes = ["interactive" "acp"];
      notes = "some ACP clients enable it in place of invoke_sub_agent";
      pinsEffort = false;
      pinsModel = false;
    };
    run_workflow = {
      kind = "workflow";
      modes = ["interactive"];
      notes = "`modelId`/`effortLevel` per step (step > workflow > session); hidden unless workflows are enabled; an unknown modelId fails mid-run, so put pinned steps first";
      pinsEffort = true;
      pinsModel = true;
    };
  };
}
