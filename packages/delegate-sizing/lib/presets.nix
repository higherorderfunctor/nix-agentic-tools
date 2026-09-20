{
  claude = {
    checkUsage = ''
      Run this read-only usage check in Bash. The OAuth token stays in a local
      variable, is never printed, and is unset on exit. Read both utilization
      windows; null model sub-limits mean no active separate limit.

      ```bash
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      set +x
      trap 'unset delegate_usage_token' EXIT
      delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)
      curl --fail --silent --show-error --config - <<EOF | jq '{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'
      url = "https://api.anthropic.com/api/oauth/usage"
      header = "Authorization: Bearer $delegate_usage_token"
      header = "anthropic-beta: oauth-2025-04-20"
      EOF
      ```

      Compare `five_hour.utilization` and `seven_day.utilization`, with their
      `resets_at` values. Never echo the credential or put it in a command log.
    '';
    delegateTools = ''
      The Agent tool accepts `model` in `fable`, `haiku`, `opus`, `sonnet`.
      It has NO per-call effort control: effort inherits the session. If the
      selected effort differs, use Workflow or a headless launch; a prompt
      sentence cannot set effort. For Haiku, effort is not applicable.

      Workflow `agent(prompt, {model, effort})` accepts `low`, `medium`, `high`,
      `xhigh`, `max`. Set both controls explicitly for models with effort.
      Both Agent-tool work and Workflow nodes can reach an extra runtime via
      a Bash step running its external launch line.
    '';
    introspectModels = ''
      Read the live Agent tool's `model` enum and the `maxEffortLevel` clamps
      in settings. Workflow's effort ladder is `low`, `medium`, `high`,
      `xhigh`, `max`; Haiku has no effort knob. Check the applicable clamp
      before claiming a requested effort is effective.
    '';
    launch = ''
      `claude -p --model <id> --effort <level> "<prompt>"`

      Use the headless id in the table, not the short Agent alias. Haiku has
      no effort knob: omit `--effort` and record effort as not applicable.
      Launch from the current working directory. Include the task, constraints,
      accepted decisions and acceptance criteria in the prompt; tell the child
      to cd into the worktree when the task uses one.
    '';
  };
  codex = {
    checkUsage = ''
      Run `bash <skill-directory>/scripts/codex-usage.sh` to read remaining
      usage through the app-server `account/rateLimits/read` method. The script
      prints `usedPercent`, `remainingPercent` and `resetsAt`; it launches no
      model turn. Resolve `<skill-directory>` to this installed skill's path.
    '';
    delegateTools = ''
      Call `collaboration.spawn_agent` directly with explicit `model`,
      `reasoning_effort`, and `fork_turns: "none"`. Supply the bounded task,
      context and acceptance criteria in `message`. Full-history forks inherit
      the parent settings and reject overrides. No probe is needed: the live
      tool advertises model ids and effort ladders.

      Follow-up messages do not resize delegates; start a new delegate to change
      the pair. The ladder is `low`, `medium`, `high`, `xhigh`, `max`; `ultra`
      on Astra, Sol and Terra means max plus automatic delegation and must
      never be selected as an effort rung. `none` is API-only for this CLI.
    '';
    introspectModels = ''
      Native spawning uses the catalog already in the tool description.
      For external CLI discovery, read `~/.codex/models_cache.json` or use
      `codex app-server`: initialize, send `initialized`, then `model/list`
      with `limit: 100` and `includeHidden: false`; follow `nextCursor` until
      null. Use `data[].model`, `supportedReasoningEfforts[].reasoningEffort`
      and `defaultReasoningEffort`. Reuse the result until the runtime changes.
      External CLI and native spawn defaults can differ; set effort explicitly.
    '';
    launch = ''
      `codex exec --model <slug> --config 'model_reasoning_effort="<level>"' --json --output-last-message <out>.md - < <prompt-file>`

      Run from the current working directory, with no `-C`, `--worktree`,
      bypass or trust flags. The brief tells the child to cd into the worktree
      for worktree-driven development. The child receives its config and repo
      files, not the host conversation: include task, decisions, constraints,
      expected output and acceptance criteria. Use unique output paths, check
      exit status and `turn.failed`/`error` events, then verify the artifact.
      A started thread or an old output file is not completion.
    '';
  };
  kiro = {
    checkUsage = false;
    delegateTools = ''
      ONLY `run_workflow` / `update_workflow` step nodes carry both `modelId`
      and `effortLevel`: step overrides workflow, which overrides session.
      `orchestrate_subagent` cannot pin either. Run `validate_workflow` first
      and read `warnings`; an unknown `modelId` can pass validation and then
      hard-fail at session creation. Unsupported `effortLevel` silently
      reconciles to the model default. Put model-pinned steps early.
    '';
    introspectModels = ''
      Run the live list FIRST and pin only ids it returns:
      `kiro-cli chat --list-models -f json | jq -r '.models[].model_id'`.
      The table is filtered against the packaged catalog at build time; it
      cannot establish this session's availability. This account has no Astra
      or Fable. Kiro spells Haiku `claude-haiku-4.5` (dot), while Claude's
      headless spelling uses `claude-haiku-4-5` (hyphen).

      For per-model effort ladders use the read-only ACP probe:
      `kiro-cli acp --agent-engine v3 --auth-method cli`. Initialize with
      `protocolVersion: 1` and `clientCapabilities: {terminal: false}`, create
      a `session/new` with the current `cwd` and `mcpServers: []`, then query
      `_kiro/config/template` for that session's model configuration. Read
      the returned effort choices/default for each selected model; send no
      inference prompt. The explicit v3 engine and `terminal: false` matter:
      ACP otherwise defaults to v2, and terminal capability can break session
      creation. Auth refresh may require interactive login; report that gap.

      Opus 5 and Sonnet 5 expose low through max (including xhigh); Sol, Terra
      and Luna also expose none. This harness defaults those models to high.
      Haiku has no effort control; `effortLevel` is a silent no-op for it.
    '';
    launch = ''
      `kiro-cli chat --no-interactive --model gpt-5.6-luna "<prompt>"`

      Employer credits: fixture probes only, pin Luna. Use only when the user
      names Kiro; this manual launch is not a general implementation delegate.
      Confirm the id in the live list before launching.
    '';
  };
}
