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
      notes = ''`collaboration.spawn_agent` with `fork_turns: "none"`, `model`, `reasoning_effort`, `task_name` and the full brief; without fork_turns "none" it inherits and refuses overrides; never select `ultra`'';
      pinsEffort = true;
      pinsModel = true;
    };
    usage = {
      command = codexUsageScript;
      kind = "usage";
      notes = "read `usedPercent`, `remainingPercent`, `resetsAt`";
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
      modes = ["interactive"];
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
