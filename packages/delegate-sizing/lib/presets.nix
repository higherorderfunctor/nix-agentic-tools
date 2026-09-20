# Runtime instruction blocks. The renderer puts native controls before external
# launches and keeps manual-only delegates after all automatic candidates.
{codexUsageScript}: {
  claude = {
    checkUsage.text = ''
      Read `five_hour.utilization` and `seven_day.utilization` with this command.
      Requires `curl` and `jq`. The token is unset after the request.

      ```bash
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
      curl --fail --silent --show-error --config - <<EOF_USAGE | jq '{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'
      url = "https://api.anthropic.com/api/oauth/usage"
      header = "Authorization: Bearer $delegate_usage_token"
      header = "anthropic-beta: oauth-2025-04-20"
      EOF_USAGE
      unset delegate_usage_token
      ```
    '';
    delegateTools.text = ''
      Use Workflow `agent(prompt, {model, effort})` with effort `low`, `medium`,
      `high`, `xhigh` or `max`. The Agent tool accepts `model: "fable"`,
      `"haiku"`, `"opus"` or `"sonnet"`, but inherits session effort.
      If that differs from your choice, use Workflow, or a shell step running `claude -p --model <id> --effort <level> "<prompt>"`.
      Haiku has no effort control. Use a shell step for an external delegate.
      When launching an external delegate from a shell step, use the harness's own background mechanism alone; do not also detach the process with `nohup` or a trailing `&`.
      Detaching makes the harness report the step as finished while the delegate is still running, so a later step reads a half-written tree.
    '';
    introspectModels.text = ''
      Read the Agent tool's `model` enum and the `maxEffortLevel` settings
      clamps before choosing. Workflow accepts `low`, `medium`, `high`,
      `xhigh` and `max`; Haiku has no effort control.
    '';
    launch.text = ''
      `claude -p --model <id> --effort <level> "<prompt>"`

      Use the table's headless id. Omit `--effort` for Haiku.
      Include the task, decisions, constraints and acceptance criteria in the
      prompt. Tell the delegate to enter the worktree if the task uses one.
    '';
  };
  codex = {
    checkUsage.text = ''
      Run `bash ${codexUsageScript}` from this installed
      skill to read `usedPercent`, `remainingPercent` and `resetsAt`.
      Requires GNU `timeout`, `jq`, Python 3 and `codex` on PATH.
    '';
    delegateTools.text = ''
      Call `collaboration.spawn_agent` with `model: "<slug>"`,
      `reasoning_effort: "<level>"`, `fork_turns: "none"`, a `task_name`
      and the complete brief in `message`. Use the live tool's model and effort
      list; no probe is needed. Start a new delegate to change model or effort.
      Efforts are `low`, `medium`, `high`, `xhigh` and `max`.
      Never select `ultra`: it adds automatic delegation to `max`.
    '';
    introspectModels.text = ''
      For external delegates, read `''${CODEX_HOME:-$HOME/.codex}/models_cache.json` or start
      `codex app-server`: send `initialize`, then `initialized`, then
      `model/list` with `limit: 100` and `includeHidden: false`.
      Follow `nextCursor` until null. Read `data[].model`,
      `supportedReasoningEfforts[].reasoningEffort` and `defaultReasoningEffort`.
    '';
    launch.text = ''
      `codex exec --model <slug> --config 'model_reasoning_effort="<level>"' --json --output-last-message <out>.md - < <prompt-file>`

      Launch from the current working directory. Use no `-C`, `--worktree`,
      bypass or trust flags. Put the task, decisions, constraints and acceptance
      criteria in the brief; tell the delegate to enter the worktree if needed.
      Use a fresh output path.
      The terminal `-` with `< <prompt-file>` already closes stdin; do not also
      append `</dev/null`, which wins the redirect and sends an empty prompt.
      Check the exit code and `turn.failed`/`error`
      events, then verify the output.
    '';
  };
  kiro = {
    checkUsage = {enable = false;};
    delegateTools.text = ''
      Set `modelId` and `effortLevel` on `run_workflow` / `update_workflow`
      steps. Step values override workflow values, which override the session.
      `orchestrate_subagent` cannot pin either. Call `validate_workflow` first
      and read `warnings`: unknown ids fail at session creation; unsupported
      efforts silently use the model default. Put steps with pinned models early.
    '';
    introspectModels.text = ''
      Run `kiro-cli chat --list-models -f json | jq -r '.models[].model_id'`
      first and pin only ids it returns. This catalog has no Astra or Fable.

      For effort choices, run `kiro-cli acp --agent-engine v3 --auth-method cli`.
      Send `initialize` with `protocolVersion: 1` and
      `clientCapabilities: {terminal: false}`, then `session/new` with the
      current `cwd` and `mcpServers: []`. Query `_kiro/config/template` for
      that session and read the selected model's effort choices.
      Opus 5 and Sonnet 5 accept `low`, `medium`, `high`, `xhigh`, `max`;
      Sol, Terra and Luna also accept `none`. Set effort every time; the default
      here is `high`. Haiku has no effort control.
    '';
    launch.text = ''
      `kiro-cli chat --no-interactive --model gpt-5.6-luna --effort <level> "<prompt>"`

      Employer credits: fixture probes only, pin Luna.
    '';
  };
}
