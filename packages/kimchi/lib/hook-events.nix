# Kimchi 1.1.37's lifecycle events, FULL_COMMAND_HOOK_EVENTS
# (src/extensions/hook-adapters/discovery.ts:29-50). Every portable event
# except PermissionRequest is among them, and the reader skips an event
# outside this list without a word (:131).
[
  "MessageEnd"
  "MessageStart"
  "ModelSelect"
  "Notification"
  "PostCompact"
  "PostToolBatch"
  "PostToolUse"
  "PostToolUseFailure"
  "PreCompact"
  "PreToolUse"
  "SessionEnd"
  "SessionStart"
  "Stop"
  "StopFail"
  "SubagentStart"
  "SubagentStop"
  "TaskCompleted"
  "TurnStart"
  "UserBash"
  "UserPromptSubmit"
]
