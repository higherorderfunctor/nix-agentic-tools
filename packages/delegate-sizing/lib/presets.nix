# Runtime instruction blocks. The renderer puts native controls before external
# launches and keeps manual-only delegates after all automatic candidates.
{
  claude = {
    checkUsage = ''
      Read `five_hour.utilization` and `seven_day.utilization` with this command.
      The token stays in a variable and is unset on exit.

      ```bash
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      set +x
      trap 'unset delegate_usage_token' EXIT
      delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)
      curl --fail --silent --show-error --config - <<EOF_USAGE | jq '{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'
      url = "https://api.anthropic.com/api/oauth/usage"
      header = "Authorization: Bearer $delegate_usage_token"
      header = "anthropic-beta: oauth-2025-04-20"
      EOF_USAGE
      ```
    '';
    delegateTools = ''
      Use Workflow `agent(prompt, {model, effort})` with effort `low`, `medium`,
      `high`, `xhigh` or `max`. The Agent tool accepts `model: "fable"`,
      `"haiku"`, `"opus"` or `"sonnet"`, but inherits session effort.
      If that differs from your choice, use Workflow or `claude -p`.
      Haiku has no effort control. Use a Bash step for an external delegate.
    '';
    introspectModels = ''
      Read the Agent tool's `model` enum and the `maxEffortLevel` settings
      clamps before choosing. Workflow accepts `low`, `medium`, `high`,
      `xhigh` and `max`; Haiku has no effort control.
    '';
    launch = ''
      `claude -p --model <id> --effort <level> "<prompt>"`

      Use the table's headless id. Omit `--effort` for Haiku.
      Include the task, decisions, constraints and acceptance criteria in the
      prompt. Tell the delegate to enter the worktree if the task uses one.
    '';
  };
  codex = {
    checkUsage = ''
      Run `bash <skill-directory>/scripts/codex-usage.sh` from this installed
      skill to read `usedPercent`, `remainingPercent` and `resetsAt`.
    '';
    delegateTools = ''
      Call `collaboration.spawn_agent` with `model: "<slug>"`,
      `reasoning_effort: "<level>"`, `fork_turns: "none"`, a `task_name`
      and the complete brief in `message`. Use the live tool's model and effort
      list; no probe is needed. Start a new delegate to change model or effort.
      Efforts are `low`, `medium`, `high`, `xhigh` and `max`.
      Never select `ultra`: it adds automatic delegation to `max`.
    '';
    introspectModels = ''
      For external delegates, read `~/.codex/models_cache.json` or start
      `codex app-server`: send `initialize`, then `initialized`, then
      `model/list` with `limit: 100` and `includeHidden: false`.
      Follow `nextCursor` until null. Read `data[].model`,
      `supportedReasoningEfforts[].reasoningEffort` and `defaultReasoningEffort`.
    '';
    launch = ''
      `codex exec --model <slug> --config 'model_reasoning_effort="<level>"' --json --output-last-message <out>.md - < <prompt-file>`

      Launch from the current working directory. Use no `-C`, `--worktree`,
      bypass or trust flags. Put the task, decisions, constraints and acceptance
      criteria in the brief; tell the delegate to enter the worktree if needed.
      Use a fresh output path. Check the exit code and `turn.failed`/`error`
      events, then verify the output.
    '';
  };
  kiro = {
    checkUsage = false;
    delegateTools = ''
      Set `modelId` and `effortLevel` on `run_workflow` / `update_workflow`
      steps. Step values override workflow values, which override the session.
      `orchestrate_subagent` cannot pin either. Call `validate_workflow` first
      and read `warnings`: unknown ids fail at session creation; unsupported
      efforts silently use the model default. Put steps with pinned models early.
    '';
    introspectModels = ''
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
    launch = ''
      `kiro-cli chat --no-interactive --model gpt-5.6-luna "<prompt>"`

      Employer credits: fixture probes only, pin Luna. This manual-only launch
      has no explicit effort flag; check the effort settings before proceeding.
    '';
  };
}
